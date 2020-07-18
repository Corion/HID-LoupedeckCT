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
    'r|reset' => \my $reset_first,
) or pod2usage(2);

my @commands;

while(my( $command,$parameters) = splice @ARGV,0,2) {
    $command = eval "0x" .$command;
    $parameters =~ s!\\x([a-f0-9]+)!pack 'H2', $1!gie;
    push @commands, [$command,$parameters];
};

my $ld = HID::LoupedeckCT->new(
    maybe uri => $uri,
);

my $today = strftime '%y%m%d-%H%M%S', localtime;
my $logname = sprintf 'cmd-%04x-%s.log', $commands[0]->[0], $today;
open my $log, '>', $logname
    or die "Couldn't create log file '$logname'";

$ld->on('hexdump' => sub {
    my ($ld, $prefix,$line) = @_;
    say $prefix . $line;
    say $log $prefix . $line;
});

say "Connecting to " . $ld->uri;

my $sequence = $ld->connect()->then(
  sub {
      if( $reset_first ) {
          return $ld->send_command(0x0406, "\x00")
      } else {
          return Future->done
      };
  }
);
for my $c (@commands) {
    my ($command,$parameters) = @$c;
    $sequence = $sequence->then(sub {
        #my ($command,$parameters) = ($command,$parameters);
        my $res = eval {
            $ld->send_command($command, $parameters)->then(sub($info,$data) {
                eval {
                    use Data::Dumper;
                    say Dumper $info->{data};
                    say $log Dumper $info->{data};
                }; warn $@ if $@;
                Future->done();
            });
        }; warn $@ if $@;
        return $res
    });
};
$sequence->then(sub {
    #warn "Done, waiting to stop";
    Mojo::IOLoop->stop;
})->retain;
    # No reply for 0x0305, 0x0306, 0x0308
    #                          0xxx02 - reply but no action
    #                          0x0702 - set button 10+ color (rgb)
    #                          0x0703 - serial
    # unknown request/response 0x0503 # - serial number
    # unknown request/response 0x0504 # - selftest
    # unknown request/response 0x0304 # - selftest
    # unknown request/response 0x0404 (selftest)
    # unknown request/response 0x0406 "\x00" reset/loupedeck circle (param are anything)
    # unknown request/response 0x0407 # firmware version
    # unknown request/response 0x0409 # backlight
    # unknown request/response 0x040c # BT config?!
    # unknown request/response 0x040d # MCU config?!
    # unknown request/response 0x040e # echo?!
    # unknown request/response 0xxx0f # "\x00\x41" redraw
    # unknown request/response 0x040f # "\x01\x07\x00\x00\x00" ->error, redraw?!
    # unknown request/response 0xxx10 # set screen bits
    # unknown request/response 0xxx11 # ??? 14141414 , no matter what command/
    # unknown request/response 0xxx12 # ??? enables keyboard? \x01\x02\x03\x04\x05\x06
    # unknown request/response 0xxx12 # ??? enables keyboard? \xff\x02\x03\x04\x05\x06
    # unknown request/response 0xxx12 # ??? nothing, "OK"     \x00\x00\x00\x00\x00\x00
    # unknown request/response 0xxx12 # ??? nothing, "OK"     \x01\x00\x00\x00\x00
    # unknown request/response 0xxx12 # ??? enables keyboard? \x41\x00\x00\x7f\x7f\x7f00\x00
    # unknown request/response 0xxx12 # ??? simulate mouse release \x00\x40\xff\x40\x44
    # unknown request/response 0xxx12 # ??? simulate mouse click   \x01\x40\xff\x40\x44
    # unknown request/response 0x0413 # "\x00" -> "OK"
    # unknown request/response 0xxx13 # "\x01\x00\x10\x00" -> "wait for enter key?!"
    # unknown request/response 0xxx13 # "\x01\xXX\xXX\xXX" -> "control key down"
    # unknown request/response 0xxx13 # "\x02\xXX\xXX\xXX" -> "shift key down"
    # unknown request/response 0xxx13 # "\x04\xXX\xXX\xXX" -> "alt/meta key down"
    # unknown request/response 0xxx13 # "\x08\xXX\xXX\xXX" -> "windows/hyper key down"
    # unknown request/response 0xxx13 # "\x10\xXX\xXX\xXX" -> "right ctrl key down?"
    # unknown request/response 0xxx13 # "\x20\xXX\xXX\xXX" -> "right shift down?"
    # unknown request/response 0xxx13 # "\x40\xXX\xXX\xXX" -> "right alt down?"
    # unknown request/response 0x0213 # "\x80\xXX\xXX\xXX" -> "windows/hyper key down?"
    # unknown request/response 0xxx14 # no response
    # unknown request/response 0xxx15 # no response
    # unknown request/response 0xxx16 # \x00 - error
    # unknown request/response 0x0417 # "\x00\x00\x00\x00\x00\x00\x00\x00" -> "OK"
    # unknown request/response 0x0417 # "\x01\x00\x00\x00\x00\x00\x00\x00" -> "nOK"
    # unknown request/response 0x0418 # "\x01\x00\x00\x00\x00\x00\x00\x00" -> "nOK" ???
    # unknown request/response 0x0419 # set register
    # unknown request/response 0x001A # read register
    # unknown request/response 0x001B # set vibration pattern
    # unknown request/response 0x001C # checksum?
    # unknown request/response 0x001d # - ? no response
    # unknown request/response 0x041e # wheel sensitivity
    # unknown request/response 0x041f # \x00 -> "OK", resets?!
    # unknown request/response 0x0420 # register -> 0x0820, 4 bytes register, 0?!
    # unknown request/response 0x0421 # \x00 -> "\x0ff"
    # unknown request/response 0x0422 # -
    # unknown request/response 0x0423 # \x00 x 17 -> \x00\x00\x00 (RGB?)
    # unknown request/response 0x0423 # \x00 x 27 -> \x00\xff\x00 (RGB?)
    # 425, 426 - no reply

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
