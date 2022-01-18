# -*- mode: perl; indent-tabs-mode: nil; perl-indent-level: 4 -*-
# vim: autoindent tabstop=4 shiftwidth=4 expandtab softtabstop=4 filetype=perl

package toolbox::registry;

use strict;
use warnings;
use JSON::JQ;
use Data::Dumper;

use Exporter qw(import);
our @EXPORT = qw(get_registry_val);

BEGIN {
    if (!exists $ENV{'CRUCIBLE_REGISTRY'} ) {
        print "This script requires a JSON file that is provided by the registry project.\n";
        print "Registry can be acquired from https://github.com/perftool-incubator/registry and\n";
        print "then use 'export CRUCIBLE_REGISTRY=/path/to/crucible-registry.json' so that it can be located.\n";
        exit 1;
    }
}

# get_registry_val takes 1 param, the registry key for which you want the value.
# All keys should use DNS naming conventions ([a-z][A-Z][0-9][.-]).
# If a key is not found, a "undef" will be returned.  Obviously, "undef" should not
# be stored as a value in the registry.

sub get_registry_val {
    my $key = shift;
    my $scr = "";
    foreach my $i (split(/\./, $key)) {
        $scr .= '."' . $i . '"';
    }
    my $jq = JSON::JQ->new({ script => $scr });
    my $results = $jq->process({ json_file => $ENV{'CRUCIBLE_REGISTRY'}});
    #print Dumper $results;
    if (defined $$results[0]) {
        return $$results[0];
    } else {
        return "undef";
    }
}

1;
