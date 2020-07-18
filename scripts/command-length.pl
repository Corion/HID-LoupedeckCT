#!perl
use strict;
use 5.020;
use experimental 'signatures';

use Getopt::Long;
use Pod::Usage;
use POSIX 'strftime';
use PerlX::Maybe;

use HID::LoupedeckCT;

GetOptions(
    'uri=s' => \my $uri,
    'f|from=s' => \my $from,
    't|to=s' => \my $to,
) or pod2usage(2);

my ($command, $parameters, $pad) = @ARGV;
$pad ||= "\x00";

$command = eval "0x" .$command;
$parameters =~ s!\\x([a-f0-9]+)!pack 'H2', $1!gie;
$pad =~ s!\\x([a-f0-9]+)!pack 'H2', $1!gie;

my $ld = HID::LoupedeckCT->new(
    maybe uri => $uri,
);

my $today = strftime '%y%m%d-%H%M%S', localtime;
my $logname = sprintf 'cmd-%04x-%s.log', $command, $today;
open my $log, '>', $logname
    or die "Couldn't create log file '$logname'";

$ld->on('hexdump' => sub {
    my ($ld, $prefix,$line) = @_;
    say $prefix . $line;
    say $log $prefix . $line;
});

say "Connecting to " . $ld->uri;

$ld->connect()->then(sub {
    for my $append( $from...$to ) {
        my $p = $parameters . (join "", $pad x $append );
        $ld->send_command($command, $p)->then(sub($info,$data) {
            say "Reply received";
            use Data::Dumper;
            say Dumper $info->{data};
            say $log Dumper $info->{data};
            exit;
        })->retain;
  };
})->retain;

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
