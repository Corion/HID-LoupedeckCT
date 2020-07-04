#!perl
use strict;
use 5.020;
use experimental 'signatures';
use Mojo::UserAgent;
use Mojo::WebSocket qw(WS_PING);
use Getopt::Long;
use Pod::Usage;

use IO::Interface::Simple; # for autodetection of the Loupedeck CT network "card"

use Future::Mojo;

use Imager;

GetOptions(
    'uri=s' => \my $uri,
) or pod2usage(2);

if( !$uri ) {
    for my $i (IO::Interface::Simple->interfaces) {
        if( $i->address =~ m/^(100\.127\.\d+)\.2$/ ) {
            $uri = "ws://$1.1/";
            last;
        };
    };
};

my $ua = Mojo::UserAgent->new();

my %callbacks;
my $cbid = 1;

my $highlight = 7;
my $brightness;

my @forever;

my ($drawtop, $drawleft) = (100,100);

sub hexdump( $prefix, $str ) {
    my @bytes = map { ord($_) } split //, $str;
    while( @bytes ) {
        my @line = splice @bytes, 0, 16;

        while (@line < 16) {
            push @line, undef
        };
        my $line = $prefix . join( " ", map { defined($_) ? sprintf '%02x', $_ : '--' } @line)
                           . "    "
                           . join( '', map { $_ && $_ >= 32 ? chr($_) : '.' } @line);
        say $line;
    };
}

sub send_command( $tx, $command, $payload ) {
    $callbacks{ $cbid } = my $res = Future::Mojo->new($ua->ioloop);
    #warn "Installed callback $cbid";
    my $p = pack( "nC", $command, $cbid) . $payload;
    hexdump('> ',$p);

    $tx->send({ binary => $p });
    $cbid = ($cbid+1) % 256;
    return $res;
}

sub clamp($value_ref, $min, $max) {
    if( $$value_ref < $min ) {
	$$value_ref = $min
    } elsif( $$value_ref > $max ) {
	$$value_ref = $max
    }
};

my $w = $ua->websocket($uri => sub {
    my ($ua, $tx) = @_;
    say 'WebSocket handshake failed!' and return unless $tx->is_websocket;
    $tx->on(binary => sub {
      my ($tx, $raw) = @_;

      hexdump('< ',$raw);
      # Dispatch it, if we have a receiver for it:
      my @res = unpack 'nCa*', $raw;
      my %res = (
          code     => $res[0],
          code_vis => sprintf( '%04x', $res[0] ),
          cbid   => $res[1],
          data => $res[2],
      );

# XXX Convert this to a Mojo 'on' handler
      my $id = $res{ cbid };
      my $f = delete $callbacks{ $id };
      if( $res{ code } == 0x0501 ) {
          #hexdump('* ', $res{ data });
          my ($knob,$direction) = unpack 'Cc', $res{data};
          if   ( $knob == 5 ) { $drawtop += $direction }
	  elsif( $knob == 4 ) { $drawleft += $direction }
	  elsif( $knob == 1 ) { $brightness += $direction }

	  clamp( \$brightness, 0, 10 );

	  set_backlight_level($tx, $brightness)->retain;
          #set_screen_color($tx, 'wheel', 255,255,0, $drawtop, $drawleft, 15, 15)->retain;
      } else {
          # Call the future
          if( $f ) {
              eval {
                  #warn "Dispatching callback $id";
                  $f->done( \%res, $raw );
              };
              warn $@ if $@;
          };
      };
    });

    push @forever, Mojo::IOLoop->recurring( 10 => sub {
        $tx->send([1, 0, 0, 0, WS_PING, 'ping']);
    });

        #push @forever, Mojo::IOLoop->recurring( 5 => sub {
        #       button_color($tx,$highlight,0,0,0);
        #       $highlight = ((($highlight-7)+1)%20)+7;
        #       button_color($tx,$highlight,127,127,127);
        #});

        #my $lv = 1;
        #push @forever, Mojo::IOLoop->recurring( 1 => sub {
        #    $lv <<= 1;
        #    set_register($tx,2,$lv)->retain;
        #});

    #$tx->send({json => {msg => 'Hello World!'}});
    initialize($tx);
    #redraw_screen($tx,"wheel");
    #redraw_screen($tx,"middle");
    #button_color($tx,7,0,0,0);
    #set_screen_color($tx,'right',0,255,255);
    #update_screen($tx);
});

sub initialize( $tx ) {
    restore_backlight_level($tx)->retain;
    get_backlight_level($tx)->then(sub($val) {
	$brightness = $val;
    })->retain;
        #push @stuff, get_backlight_level($tx);
        #push @stuff, set_flashdrive($tx,1);
        get_serial_number($tx)->then(sub(%versions) {
            use Data::Dumper; warn Dumper \%versions;
        })->retain;
        get_firmware_version($tx)->then(sub(%versions) {
            use Data::Dumper; warn Dumper \%versions;
        })->retain;
        #push @stuff, read_register($tx,0);
        #push @stuff, read_register($tx,1);
        read_register($tx,2)->retain;
        #push @stuff, read_register($tx,3);
        #push @stuff, read_register($tx,4);
        set_register($tx,2,0x02000819)->retain;
        #push @stuff, set_register($tx,2, );
        #push @stuff, button_color($tx, 7,127,127,0);
    #set_screen_color($tx,'left',0,0,0);
    #set_screen_color($tx,'middle',0,0,0);
    #set_screen_color($tx,'right',0,0,0);
    #set_screen_color($tx,'wheel',0,0,0);

};

our %screens = (
    left   => { id => 0x004c, width =>  60, height => 270, },
    middle => { id => 0x0041, width => 360, height => 270, },
    right  => { id => 0x0052, width =>  60, height => 270, },
    wheel  => { id => 0x0057, width => 240, height => 240, },
);

sub redraw_screen( $tx, $screen ) {
        #warn "Redrawing '$screen'";
    #send_command( $tx, 0x050f, undef, "\x0b\x03" . pack("n", $screens{$screen}->{id} ));
    send_command( $tx, 0x050f, pack("n", $screens{$screen}->{id} ));
};

sub _rgb($r,$g,$b) {
        my $bit =
          ((($r >> 3) & 0x1f) << 3)
        + (($g >> 5) & 0x07)
        + ((($b >> 3) & 0x1f) << 8);
        return pack 'n', $bit
};

sub _rgbRect($width,$height,$r,$g,$b) {
        _rgb($r,$g,$b) x ($width*$height)
}

sub set_screen_color( $tx, $screen, $r,$g,$b, $top=0, $left=0, $width=undef,$height=undef ) {
        $width //= $screens{$screen}->{width};
        $height //= $screens{$screen}->{height};
        #my $screen = 'middle';
        #my $payload = "\x00\x57\x00\x00\x00\x00" . "\x00\x3c\x01\x0e" # . pack('nn', $width,$height)

        #my $image = join "", map { _rgb(255,0,0) } 1..($width*$height);
        my $image = _rgbRect( $width,$height, $r,$g,$b );
        my $payload = pack("n", $screens{$screen}->{id} ) . pack('nnnn', $left, $top, $width,$height);
        $payload .= $image;
        send_command( $tx, 0xff10, $payload );
        redraw_screen($tx, $screen);
}

sub update_screen( $tx, $top=0, $left=0, $width=undef,$height=undef ) {
        $width //= 15;
        $height //= 15;
        my $screen = 'middle';
        #my $payload = "\x00\x57\x00\x00\x00\x00" . "\x00\x3c\x01\x0e" # . pack('nn', $width,$height)

        #my $image = join "", map { _rgb(255,0,0) } 1..($width*$height);
        my $image = _rgbRect( $width,$height, 255,0,0 );
        #warn "$screen ($left,$top : ${width}x$height)";
        my $payload = pack("n", $screens{$screen}->{id} ) . pack('nnnn', $left, $top, $width,$height)
            . $image;
        send_command( $tx, 0xff10, $payload );
        redraw_screen($tx, $screen);
}

    # round buttons: 7 to 14
    # square buttons: 15 to 26
sub button_color( $tx, $button, $r, $g, $b ) {
    my $payload = pack "cccc", $button, $r, $g, $b;
    send_command( $tx, 0x0702, $payload );
}

sub read_register( $tx, $register ) {
    return send_command($tx, 0x041A, chr($register))->then(sub($info,$data) {
        #use Data::Dumper; warn Dumper [$info,$data];
        my( $register,$value ) = unpack 'CN', $info->{data};
        return Future::Mojo->done(
            register => $register,
            value    => $value,
        );
    });
}

sub set_register( $tx, $register, $value ) {
    my $update = pack 'CN', $register, $value;
    return send_command($tx, 0x0819, $update)
}

sub get_backlight_level( $tx ) {
    return read_register($tx,2)->then(sub(%result) {
        my $val = ($result{value} & 0x0000ff00) >> 8;
        return Future::Mojo->done($val);
    });
}

sub set_backlight_level( $tx, $level ) {
    # Store the persistent backlight level
    return read_register($tx,2)->then(sub(%result) {
        my $val = ($result{value} & 0x0000ff00) >> 8;
        warn "Backlight level is $val, setting to $level";
        if( $val != $level ) {
            $result{ value } = ($result{value} & 0xffff00ff) | ($level << 8);
            return set_register($tx, 2, $result{value});
        } else {
            return Future::Mojo->done;
        };
    })->then(sub {
	send_command($tx,0x0409,chr($level))
    });;
}

sub restore_backlight_level( $tx ) {
    return get_backlight_level($tx)->then(sub($level) {
	return set_backlight_level($tx,$level);
    });
}

sub vibrate( $tx, $sequence ) {
    return send_command($tx, 0x041B, chr($sequence))
}

=item *

Enables or disables the built-in flash drive

You might need to unplug and replug the device to get the flash drive
recognized by your system.

=cut

sub set_flashdrive( $tx, $value ) {
    $value = (!$value) ? 1 : 0;
    return read_register($tx,0)->then(sub(%result) {
        #use Data::Dumper; warn Dumper \%result;
        warn sprintf "Value is %08x", $result{value};
        my $val = ($result{value} & 0x00000001);
        warn "Flash drive enabled is $val, setting to $value";
        if( $val != $value ) {
            $result{ value } = ($result{value} & 0xfffffffe) | ($value);
            warn sprintf "Value is %08x", $result{value};
            return set_register($tx, 0, $result{value});
        } else {
            return Future::Mojo->done;
        };
    });
}

sub get_firmware_version( $tx ) {
    return send_command($tx, 0x0307, '')->then(sub( $info, $data ) {

        my @versions = unpack 'a3a3a3', $info->{ data };
        my %result;
        $result{b} = sprintf '%d.%d.%d', map { ord($_)} split //, shift @versions;
        $result{c} = sprintf '%d.%d.%d', map { ord($_)} split //, shift @versions;
        $result{i} = sprintf '%d.%d.%d', map { ord($_)} split //, shift @versions;
        #use Data::Dumper; warn Dumper \%result;
        return Future::Mojo->done( %result )
    })->catch(sub {
        warn "Error!";
        use Data::Dumper; warn Dumper \@_;
    });
}

sub get_serial_number( $tx ) {
    return send_command($tx, 0x0303, '')->then(sub( $info, $data ) {
        #my @versions = unpack 'a3a3a3', $info->{ data };
        #my %result;
        #$result{b} = sprintf '%d.%d.%d', map { ord($_)} split //, shift @versions;
        #$result{c} = sprintf '%d.%d.%d', map { ord($_)} split //, shift @versions;
        #$result{i} = sprintf '%d.%d.%d', map { ord($_)} split //, shift @versions;
        #use Data::Dumper; warn Dumper \%result;
        return Future::Mojo->done($info->{data})
    })->catch(sub {
        warn "Error!";
        use Data::Dumper; warn Dumper \@_;
    });
}

sub get_wheel_sensitivity( $tx ) {
    return send_command($tx,0x041e,"\0")->then(sub($info,$data) {
        my $val = unpack 'C', $data;
        return Future::Mojo->done($val);
    });
}

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
