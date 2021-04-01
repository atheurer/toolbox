# -*- mode: perl; indent-tabs-mode: t; perl-indent-level: 4 -*-
# vim: autoindent tabstop=4 shiftwidth=4 expandtab softtabstop=4 filetype=perl

package toolbox::metrics;

use Exporter qw(import);
our @EXPORT = qw(log_sample finish_samples);

use strict;
use warnings;
use IO::File;

our %metric_idx;
our @stored_sample;
our @num_written_samples;
our @interval;
our $total_logged_samples;
our $total_cons_samples;
our %inter_sample_interval;
my $use_xz = 1;
my $metric_data_file = "metric-data.csv";
my $metric_data_fh;

sub write_sample {
    my $idx = shift;
    my $begin = shift;
    my $end = shift;
    my $value = shift;
    if ($value > 0) {
        printf "%d,%d,%d,%f\n", $idx, $begin, $end, $value;
    }
    printf { $metric_data_fh } "%d,%d,%d,%f\n", $idx, $begin, $end, $value;
    if (defined $num_written_samples[$idx]) {
        $num_written_samples[$idx]++;
    } else {
        $num_written_samples[$idx] = 1;
    }
}

sub get_metric_label {
    my $desc_ref = shift;
    my $names_ref = shift;
    my $label;

    # Build a label to uniquely identify this metric type
    foreach my $name (sort keys %$names_ref) {
        my $value;
        if (exists $$names_ref{$name} and defined $$names_ref{$name})  {
            $value = $$names_ref{$name};
        } else {
            $value = "x";
        }
        $label .= "<" . $name . ":" . $value . ">";
    }
    return $label;
}

sub finish_samples {
    my $metrics_ref = shift;
    my $num_splices = 0;
    printf "num_metrics: %d\n", scalar @$metrics_ref;
    printf "num_stored_samples: %d\n", scalar @stored_sample;
    # All of the stored samples need to be written
    for (my $idx = 0; $idx < scalar @stored_sample; $idx++) {
        if (defined $metric_data_fh and defined $stored_sample[$idx]) {
            if ($stored_sample[$idx]{'value'} == 0 and ! defined $num_written_samples[$idx]) {
                # This metric had only 1 sample and the value is 0, so it "did not do any work".  Therefore, we can just
                # not create this metric at all.
                # TODO: This optimization might be better if the metric source/type could opt in/out of this.
                # There might be certain metrics which users want to query and get a "0" instead of a metric
                # not existing.  FWIW, this should *not* be a problem for metric-aggregation for throughput class.
                printf "deleting metric because only sample is 0 at idx: %d (modified idx): %d label: %s\n",
                       $idx, $idx - $num_splices, get_metric_label($metrics_ref, $$metrics_ref[$idx - $num_splices]{'names'});
                splice(@$metrics_ref, $idx - $num_splices, 1);
                $num_splices++;
            } else {
                write_sample($idx, $stored_sample[$idx]{'begin'}, $stored_sample[$idx]{'end'}, $stored_sample[$idx]{'value'});
                $$metrics_ref[$idx - $num_splices]{'idx'} = $idx;
            }
        }
    }
    close($metric_data_fh);
    printf "num_deletes: %d\n", $num_splices;
}

sub log_sample {
    my $metrics_ref = shift;
    my $type = shift;
    my $desc_ref = shift;
    my $names_ref = shift;
    my $end = shift;
    my $value = shift;
    my $label = "";
    if ($use_xz == 1) {
        $metric_data_file .= ".xz";
    }

    my $label = get_metric_label($desc_ref, $names_ref);

    if (! exists $metric_idx{$label}) { # This is the first sample for this metric type (of this label)
        # This is how we track which element in the metrics_ref array belongs to this metric type
        $metric_idx{$label} = scalar @$metrics_ref;
        my $idx = $metric_idx{$label};
        # store the metric_desc info
        my %this_metric;
        $this_metric{'desc'} = $desc_ref;
        $this_metric{'names'} = $names_ref;
        $$metrics_ref[$idx] = \%this_metric;
        # Sample data will not be accumulated in a hash or array, as the memory usage
        # of this script can explode.  Instead, samples are written to a file (but we
        # also merge cronologically adjacent samples with the same valule).
        # Check for and open this file now.
        if (! defined $metric_data_fh) {
            if ($use_xz == "1") {
                $metric_data_fh = IO::Compress::Xz->new($metric_data_file, Preset => 0) || die("Could not open " . $metric_data_file . " for writing: $!");
            } else {
                open( $metric_data_fh, '>' . $metric_data_file) or die("Could not open " . $metric_data_file . ": $!");
            }
            printf "opened %s\n", $metric_data_file;
        }
        $stored_sample[$idx]{'end'} = $end;
        $stored_sample[$idx]{'value'} = $value;
        return;
    } else { 
        my $idx = $metric_idx{$label};
        # Figure out what the typical duration is between samples from the first two
        if (! defined $interval[$idx] and defined $stored_sample[$idx]{'end'}) {
            $interval[$idx] = $end - $stored_sample[$idx]{'end'}
        }
        # If this is the very first sample, we can't get a begin from a previous sample's end+1, so we
        # derive the begin by subtracting the interval from current sample's end.
        if (defined $stored_sample[$idx] and ! defined $stored_sample[$idx]{'begin'}) {
            $stored_sample[$idx]{'begin'} = $stored_sample[$idx]{'end'} - $interval[$idx];
        }
        # Once we have a sample with a different value, we can write the previous [possibly consolidated] sample
        if ($stored_sample[$idx]{'value'} != $value) {
            write_sample($idx, $stored_sample[$idx]{'begin'}, $stored_sample[$idx]{'end'}, $stored_sample[$idx]{'value'});
            $total_cons_samples++;
            # Now the new sample becomes the stored sample
            $stored_sample[$idx]{'begin'} = $stored_sample[$idx]{'end'} + 1;
            $stored_sample[$idx]{'end'} = $end;
            $stored_sample[$idx]{'value'} = $value;
        } else {
            # The new sample did not have a different value, so we update the stored sample to have a new end time
            # The effect is reducing the total number of samples (sample "dedup" or consolidation)
            $stored_sample[$idx]{'end'} = $end;
        }
        $total_logged_samples++;
        # Flush every so often in an attempt to reduce memory usage
        # (not sure if this is making a difference)
        if ($total_logged_samples % 1000000 == 0) {
            printf "Logged %d samples, wrote %d consolidated samples\n", $total_logged_samples, $total_cons_samples;
            if ($use_xz == 1) {
                $metric_data_fh->flush;
            }
        }
    }
}

1;
