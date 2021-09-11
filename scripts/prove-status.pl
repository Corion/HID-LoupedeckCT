#!/usr/bin/perl
use strict;
use warnings;
use 5.010; # for //=

use App::Prove::State;
use Getopt::Long;

GetOptions(
    'file|f=s' => \my $filename,
);
$filename //= '.prove';

my $state = App::Prove::State->new({ store => $filename });
my $results = $state->results;

my $res = 1; # passed

for my $t ($results->tests) {
    $res &&= ($t->{last_result} == 0);
};

my $exitcode = $res == 1 ? 0 : 1;
exit $exitcode;
