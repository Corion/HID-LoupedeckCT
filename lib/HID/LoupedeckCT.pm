package HID::LoupedeckCT 0.01;
use strict;
use warnings;

use 5.020;

use File::Basename 'basename';
use Mojo::UserAgent;
use Mojo::WebSocket qw(WS_PING);
use Mojo::Transaction::WebSocket::Serial;
use Mojo::Base 'Mojo::EventEmitter';
use Carp 'croak';

use Moo 2;
use PerlX::Maybe;
use Imager;

my $is_windows = ($^O =~ /\bmswin/i);
if( $is_windows ) {
    require Win32::IPConfig; # for autodetection of the Loupedeck CT network "card"

} else {
    require IO::Interface::Simple; # for autodetection of the Loupedeck CT network "card"
}

use Future::Mojo;

use experimental 'signatures';
no warnings 'experimental';

=head1 NAME

HID::LoupedeckCT - Perl driver for the Loupedeck CT keyboard

=head1 SYNOPSIS

  use feature 'say';

  my $ld = HID::LoupedeckCT->new();
  say "Connecting to " . $ld->uri;
  $ld->connect()->get;
  $ld->on('turn' => sub($ld,$info) {
      my $knob = $info->{id};
      my $direction = $info->{direction};

      # ...
  });

=head1 ACCESSORS

=head2 C<< uri >>

The (websocket) URI where the Loupedeck device can be contacted.
If not given, this is autodetected.

=cut

has 'uri' => (
    is => 'lazy',
    default => \&_build_uri,
);

=head2 C<< ua >>

The L<Mojo::UserAgent> used for talking to the Loupedeck CT.

=cut

has 'ua' => (
    is => 'lazy',
    default => sub {
        Mojo::UserAgent->new();
    },
);

=head2 C<< tx >>

The Websocket transaction used for talking.

=cut

has 'tx' => (
    is => 'ro',
);

has '_callbacks' => (
    is => 'lazy',
    default => sub { +{} },
);

has '_cbid' => (
    is => 'rw',
    default => 1,
);

has '_ping' => (
    is => 'ro',
);

sub _get_cbid( $self ) {
    my $res = $self->_cbid;
    $self->_cbid( ($res+1)%256 );
    $res
}

=head1 METHODS

=head2 C<< HID::LoupedecCT->list_loupedeck_devices >>

    my @ipv4_addresses = HID::LoupedecCT->list_loupedeck_devices;

This method lists potential candidates for USB connected Loupedeck CT
devices. It returns them as C<ws://> URIs for (USB) network connections
and as raw path names for (USB) serial connections.

=cut

sub list_loupedeck_devices_windows {
    return map {
        my $addr = join ",", $_->get_ipaddresses;
        $addr =~ m/^(100\.127\.\d+)\.2$/
        ? "ws://$1.1/"
        : ()
    } Win32::IPConfig->new->get_adapters;
}

sub list_loupedeck_devices_other {
	my @res = map {
        $_->address =~ m/^(100\.127\.\d+)\.2$/
        ? "ws://$1.1/"
        : ()
    } IO::Interface::Simple->interfaces;

    my %seen;

	# This is highly Linux-specific ...
    File::Find::find({ follow => 0, wanted => sub {
		#say "Looking at $File::Find::name";
		if( -d "$File::Find::name/tty" ) {
			my $base = $File::Find::name;
			#say "$base is a tty";
			(my $dev) = glob "$base/tty/*";
			$dev = basename $dev;
			my $descr = "$base/uevent";
			if( open my $fh, '<', $descr ) {
				if( grep { m!^PRODUCT=2ec2/3\b!i } <$fh> ) {
					# Note the device ID so we don't report duplicates here
					#say "Found USB-serial connection $File::Find::name ($dev)";
					my $d = "/dev/$dev";
					push @res, "/dev/$dev"
						unless $seen{$d}++;
				};
			};
		}}
	}, '/sys/bus/usb/devices/');

    return @res
}

sub list_loupedeck_devices($class) {
    if( $is_windows ) {
        list_loupedeck_devices_windows()
    } else {
        list_loupedeck_devices_other()
    }
}

sub _build_uri {
    (my $uri) = __PACKAGE__->list_loupedeck_devices();
    return $uri
}

=head2 C<< ->send_command $command, $payload >>

  $ld->send_command( 0x0409, "\03" )->then(sub {
      say "Set backlight level to 3.";
  });

Sends a command and returns a L<Future> that will be fulfilled with
the reply from the device.

=cut

sub send_command( $self, $command, $payload ) {
    my $cbid = $self->_get_cbid;
    $self->_callbacks->{ $cbid } = my $res = Future::Mojo->new($self->ua->ioloop);
    #warn "Installed callback $cbid";
    my $p = pack( "nC", $command, $cbid) . $payload;
    my $vis = $p;
    if( length $vis > 64 ) {
        $vis = substr( $vis,0, 61). '...';
    };
    $self->hexdump('> ',$vis);

    $self->tx->send({ binary => $p });
    return $res;
}

=head2 C<< ->hexdump $prefix, $string >>

Helper to dump bytes sent or received to STDOUT.

=cut

sub hexdump( $self, $prefix, $str ) {
    my @bytes = map { ord($_) } split //, $str;
    while( @bytes ) {
        my @line = splice @bytes, 0, 16;

        while (@line < 16) {
            push @line, undef
        };
        my $line =   join( " ", map { defined($_) ? sprintf '%02x', $_ : '--' } @line)
                   . "    "
                   . join( '', map { $_ && $_ >= 32 ? chr($_) : '.' } @line);
        $self->emit('hexdump',$prefix,$line);
    };
}

our %screens = (
    left   => { id => 0x004c, width =>  60, height => 270, },
    middle => { id => 0x0041, width => 360, height => 270, },
    right  => { id => 0x0052, width =>  60, height => 270, },
    wheel  => { id => 0x0057, width => 240, height => 240, },
);

# Touch coordinates, not pixel coordinates!
our @buttons = (
    # id, xl, yl, xr, yr
    [  0,   15, 15, 60, 260 ],

    [  1,   80, 15, 145, 90 ],
    [  2,  165, 15, 235, 90 ],
    [  3,  250, 15, 320, 90 ],
    [  4,  335, 15, 410, 90 ],

    [  5,   80, 105, 145, 175 ],
    [  6,  165, 105, 235, 175 ],
    [  7,  250, 105, 320, 175 ],
    [  8,  335, 105, 410, 175 ],

    [  9,   80, 190, 145, 260 ],
    [ 10,  165, 190, 235, 260 ],
    [ 11,  250, 190, 320, 260 ],
    [ 12,  335, 190, 410, 260 ],

    [ 13, 425,  15, 470, 260 ],
);

=head2 C<< ->button_from_xy >>

Helper to return a button number from X/Y touch coordinates

=cut

# Simple linear search through our list...
sub button_from_xy( $self, $x,$y ) {
    my $button = undef;

    for (@buttons) {
        #warn "($x,$y) | [@$_]";
        if(     $x >= $_->[1] and $x <= $_->[3]
            and $y >= $_->[2] and $y <= $_->[4] ) {
            return $_->[0];
        };
    };

    return $button;
};

=head2 C<< ->button_rect $button >>

  my( $screen, $x,$y,$w,$h ) = $ld->button_rect(6);

Helper to return rectangle coordinates from a button number

=cut

sub button_rect( $self, $button ) {
    if( $button == 0 ) {
        return ('left', 0,0,$screens{left}->{width},$screens{left}->{height});
    } elsif( $button == 13 ) {
        return ('right', 0,0,$screens{right}->{width},$screens{right}->{height});
    } else {
        my $x = int( ($button-1)%4)*90;
        my $y = int( ($button-1)/4)*90;

        return ('middle',$x,$y,90,90);
    }
};

sub on_ld_message( $self, $raw ) {
            if( $raw !~ /\A\x04\x00\00.\z/s ) {
                $self->hexdump('< ',$raw);
            };
            # Dispatch it, if we have a receiver for it:
            my @res = unpack 'nCa*', $raw;
            my %res = (
                code     => $res[0],
                code_vis => sprintf( '%04x', $res[0] ),
                cbid   => $res[1],
                data => $res[2],
            );

            my $id = $res{ cbid };
            my $f = delete $self->_callbacks->{ $id };
            if( $res{ code } == 0x0501 ) { # small encoder turn or wheel turn
                #$self->hexdump('* ', $res{ data });
                my ($knob,$direction) = unpack 'Cc', $res{data};

                $self->emit('turn' => { id => $knob, direction => $direction });

            } elsif( $res{ code } == 0x0500 ) { # key press
                #$self->hexdump('* ', $res{ data });
                my ($key,$released) = unpack 'CC', $res{data};

                $self->emit('key' => { id => $key, released => $released });

            } elsif(    $res{ code } == 0x094d
                     or $res{ code } == 0x096d
              ) { # touch press/slide
                my ($finger, $x,$y) = unpack 'Cnnx', $res{data};
                my $rel = $res{ code } == 0x096d;

                my $button = $self->button_from_xy( $x,$y );

                $self->emit('touch' => {
                    finger => $finger, released => $rel, 'x' => $x, 'y' => $y,
                    button => $button,
                });

            } elsif(    $res{ code } == 0x0952
                     or $res{ code } == 0x0972
              ) { # touch press/slide
                my ($finger, $x,$y) = unpack 'Cnnx', $res{data};
                my $rel = $res{ code } == 0x0972;

                #my $button = $self->button_from_xy( $x,$y );

                $self->emit('wheel_touch' => {
                    finger => $finger, released => $rel, 'x' => $x, 'y' => $y,
                });

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
};

=head2 C<< ->connect $uri >>

  $ld->connect->then(sub {
      say "Connected to Loupedeck";
  });

=cut

sub connect( $self, $uri = $self->uri ) {

    #$res->on_ready(sub {
    #   say "->connect() result is ready";
    #});

    my $do_connect;
    if( $uri =~ m!^wss?://!) {

        $do_connect = $self->ua->websocket_p($uri);
    } else {

        $do_connect = Mojo::Transaction::WebSocket::Serial->new(name => $uri)
            ->open_p;
    };
    return $do_connect->then(sub {
        my ($tx) = @_;
        # say 'WebSocket handshake failed!' and return unless $tx->is_websocket;
        $self->{tx} = $tx;

        #$tx->on(close => sub {
        #   say "--- closed";
        #});
        #
        #$tx->on(error => sub {
        #   say "--- error @_";
        #});

        #$tx->on(write => sub( $tx, $data ) {
        #   say "--- Write <$data>";
        #   $self->hexdump('>', $data);
        #});

        $tx->on('binary' => sub( $tx, $msg ) {
            $self->on_ld_message( $msg );
        });

    });
};

=head2 C<< ->disconnect >>

  $ld->disconnect->get;

Disconnects gracefully from the Loupedeck.

=cut

sub disconnect( $self ) {
	say "Disconnecting websocket";
	return $self->tx->finish
}

sub DESTROY {
	$_[0]->disconnect if $_[0]->{tx}
}

=head2 C<< ->read_register $register >>

  $ld->read_register(2)->then(sub {
      my ($info,$data) = @_;
      say $info->{register};
      say $info->{value};
  });

Reads the value of a persistent register.

These registers are mostly used to store configuration values on the device.

=cut

sub read_register( $self, $register ) {
    return $self->send_command(0x041A, chr($register))->then(sub($info,$data) {
        #use Data::Dumper; warn Dumper [$info,$data];
        my( $register,$value ) = unpack 'CN', $info->{data};
        return Future::Mojo->done(
            register => $register,
            value    => $value,
        );
    });
}

=head2 C<< ->read_register $register >>

  $ld->set_register(2,0x12345678)->retain;

Sets the value of a persistent 32-bit register.

These registers are mostly used to store configuration values on the device.

=cut

sub set_register( $self, $register, $value ) {
    my $update = pack 'CN', $register, $value;
    return $self->send_command(0x0819, $update)
}

=head2 C<< ->get_backlight_level >>

  $ld->get_backlight_level->then(sub {
      my( $level ) = @_;
  });

Reads the value of the backlight level stored in the device.

This level can deviate from the actual level.

=cut

sub get_backlight_level( $self ) {
    return $self->read_register(2)->then(sub(%result) {
        my $val = ($result{value} & 0x0000ff00) >> 8;
        return Future::Mojo->done($val);
    });
}

=head2 C<< ->set_backlight_level $level, %options >>

  $ld->set_backlight_level(9)->retain;

Sets the value of the backlight level and optionally stores in the device
for persistence across machines/power loss.

The level ranges from 0 (off) to 9 (bright).

If you pass in the C<persist> option, the backlight level stored in the
permanent register 2 will be updated.

  $ld->set_backlight_level(9, persist => 1)->retain;

=cut

sub set_backlight_level( $self, $level, %options ) {
    # Store the persistent backlight level
    my $do_update = $options{ persist }
                    ? $self->read_register(2)->then(sub(%result) {
                        my $val = ($result{value} & 0x0000ff00) >> 8;
                        if( $val != $level ) {
                            #warn "Backlight level is $val, setting to $level";
                            $result{ value } = ($result{value} & 0xffff00ff) | ($level << 8);
                            return $self->set_register(2, $result{value});
                        } else {
                            return Future::Mojo->done;
                        };
                      })
                    : Future->done();

    $do_update->then(sub {
        $self->send_command(0x0409,chr($level))
    });
}

=head2 C<< ->restore_backlight_level >>

  $ld->restore_backlight_level->retain;

Restores the value of the backlight level to the level stored
on the device.

Use this method at the startup of your program.

=cut

sub restore_backlight_level( $self ) {
    return get_backlight_level($self)->then(sub($level) {
        return set_backlight_level($self,$level);
    });
}

=head2 C<< ->vibrate $pattern  >>

  $ld->vibrate()->retain; # default
  $ld->vibrate(10);       # do-de

Vibrates the Loupedeck CT in the given pattern.

=cut

sub vibrate( $self, $sequence ) {
    return $self->send_command(0x041B, chr($sequence))
}

=head2 C<< ->set_flashdrive $enable >>

  $ld->set_flashdrive(1);

Enables or disables the built-in flash drive

You need to unplug and replug the device to get the flash drive
recognized by your system.

=cut

sub set_flashdrive( $self, $value ) {
    $value = (!$value) ? 1 : 0;
    return $self->read_register(0)->then(sub(%result) {
        #use Data::Dumper; warn Dumper \%result;
        #warn sprintf "Value is %08x", $result{value};
        my $val = ($result{value} & 0x00000001);
        #warn "Flash drive enabled is $val, setting to $value";
        if( $val != $value ) {
            $result{ value } = ($result{value} & 0xfffffffe) | ($value);
            #warn sprintf "Value is %08x", $result{value};
            return $self->set_register(0, $result{value});
        } else {
            return Future::Mojo->done;
        };
    });
}

sub get_firmware_version( $self ) {
    return $self->send_command(0x0307, '')->then(sub( $info, $data ) {

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

sub get_serial_number( $self ) {
    return $self->send_command(0x0303, '')->then(sub( $info, $data ) {
        return Future::Mojo->done($info->{data})
    })->catch(sub {
        warn "Error!";
        use Data::Dumper; warn Dumper \@_;
    });
}

sub get_mcu_id( $self ) {
    return $self->send_command(0x030d, '')->then(sub( $info, $data ) {
        my $id = join '', map { sprintf '%02x',$_ } unpack 'CCCCCCCCCCC', $info->{data};
        return Future::Mojo->done($id)
    })->catch(sub {
        warn "Error!";
        use Data::Dumper; warn Dumper \@_;
    });
}

sub get_self_test( $self ) {
    return $self->send_command(0x0304, '')->then(sub( $info, $data ) {
        #my $id = join '', map { sprintf '%02x',$_ } unpack 'CCCCCCCCCCC', $info->{data};
        my $result = unpack 'V', $info->{data};
        return Future::Mojo->done($result)
    })->catch(sub {
        warn "Error!";
        use Data::Dumper; warn Dumper \@_;
    });
}

sub get_loopback( $self, $echo_string ) {
    return $self->send_command(0x130e, '')->then(sub( $info, $data ) {
        #my $id = join '', map { sprintf '%02x',$_ } unpack 'CCCCCCCCCCC', $info->{data};
        return Future::Mojo->done($info->{data})
    })->catch(sub {
        warn "Error!";
        use Data::Dumper; warn Dumper \@_;
    });
}

sub get_wheel_sensitivity( $self ) {
    return $self->send_command(0x041e,"\0")->then(sub($info,$data) {
        my $val = unpack 'C', $info->{data};
        return Future::Mojo->done($val);
    });
}


# 1 - very sensitive
# 4 - default
# 8 - less sensitive
# 64 - 0.3 revolutions
# 100 - 0.5 revolutions
# 192 - 1 revolution
# 255 - 1.5 revolutions
sub set_wheel_sensitivity( $self, $new_sensitivity ) {
    return $self->send_command(0x041e,chr($new_sensitivity));
}

=head2 C<< ->reset >>

  $ld->reset

Resets/restarts the Loupedeck device

=cut

sub reset( $self ) {
    return $self->send_command(0x0406,"\x00");
}

=head2 C<< ->redraw_screen >>

  $ld->redraw_screen->retain;

This updates the screen after paint operations.

=cut

sub redraw_screen( $self, $screen ) {
        #warn "Redrawing '$screen'";
    $self->send_command( 0x050f, pack("n", $screens{$screen}->{id} ));
};

=head2 C<< ->set_button_color $button, $r, $g, $b >>

  $ld->set_button_color(10, 127,255,127)->retain;

Sets the backlight colour for a physical button. The button
values are 7 to 14 for the round buttons and 15 to 26 for the square
buttons.

=cut

sub set_button_color( $self, $button, $r, $g, $b ) {
    my $payload = pack "CCCC", $button, $r, $g, $b;
    $self->send_command( 0x0702, $payload );
}

=head2 C<< ->load_image >>

=cut

sub load_image( $self, %options ) {
    # load the image
    if( ! defined $options{ image }) {
        my $fn = delete $options{ file };
        $options{ image } = Imager->new( file => $fn)
            or croak "Couldn't load image from '$fn': $!"
    };

    my $screen = delete $options{ screen } // 'middle';

    my $x = delete $options{ left };
    my $y = delete $options{ top };
    my $w = delete $options{ width } // $HID::LoupedeckCT::screens{$screen}->{width};
    my $h = delete $options{ height } // $HID::LoupedeckCT::screens{$screen}->{height};

    my $img = delete $options{ image };

    $img = $img->scale(xpixels => $w, ypixels => $h, type => 'min');
    if( delete $options{ center }) {
        $x += int(($w-$img->getwidth)/2);
        $y += int(($h-$img->getheight)/2);
    };

    my $image_bits = '';

    # Now, convert the image to 5-6-5 16-bit color
    # this is somewhat inefficient here, but later, we'll look at using the
    # proper Imager->convert() invocation to get the 16-bit 5-6-5 memory layout
    # Maybe convert to 16-bit "grayscale"
    my $c = $img->getwidth-1;
    for my $r (0..$img->getheight-1) {
        my @colors = $img->getpixel(x => [0..$c], y => [$r]);
        $image_bits .= join "", map { _rgb($_->rgba) } @colors;
    }

    my $res = $self->set_screen_bits($screen, $image_bits, $x, $y, $img->getwidth,$img->getheight);
    if( $options{ update }) {
        $res = $res->then(sub {
            $self->redraw_screen( $screen );
        });
    };
    return $res
}

sub _text_image( $self, $w,$h, $str, %options ) {
    my $bg   = delete $options{ bgcolor } || [0,80,0];
    my $fg   = delete $options{ color } || [255,255,255];
    my $font = delete $options{ font } || '/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf';

    # Upgrade to Imager::Color objects
    for ($bg,$fg) {
        if( ref $_ eq 'ARRAY' ) {
            $_ = Imager::Color->new( @$_ );
        }
    };

    # We should size the string first and then scale things down to the target
    # ... or draw the string as large as it is, and leave the rest to the
    # lower levels of image aligning
    $font = Imager::Font->new( file => $font, type => 'ft2', size => $h, color => $fg, );

    my $btn1 = Imager->new(
        xsize => $w,
        ysize => $h,
    );
    # Size the string
    my ($l,$t,$r,$b) = $font->align( string => $str,
                  x => $w / 2,
                  y => $h / 2,
                  halign => 'center',
                  valign => 'center',
                  image => $btn1,
                );
    my ($rw, $rh) = ($r-$l, $b-$t);
    my $sz = $rw > $rh ? $rw : $rh;
    my $btn = Imager->new(
        xsize => $sz,
        ysize => $sz,
    );
    # Paint the background
    $btn->box( filled => 1, color => $bg );
    # Draw the font
    $font->align( string => $str,
                  x => $sz / 2,
                  y => $sz / 2,
                  halign => 'center',
                  valign => 'center',
                  image => $btn,
                );
    return $btn;
}

=head2 C<< ->load_image_button >>

  $ld->load_image_button(
      button  => 1,
      file    => 'logo.jpg',
      refresh => 1,
  )->get;

  $ld->load_image_button(
      button  => 1,
      string  => "\N{DROMEDARY CAMEL}",
      refresh => 1,
      bgcolor => [30,30,60],
  )->get;

Loads one of the touchscreen buttons with an image file or string.

=cut

sub load_image_button( $self, %options ) {
    my $button = delete $options{ button };

    my @r = $self->button_rect( $button);
    my ($screen,$x,$y,$w,$h) = @r;

    if( my $str  = delete $options{ string }) {
		$options{ image } = $self->_text_image( $w, $h, $str, %options );
	}

    return $self->load_image(
              screen => $screen,
              left   => $x,
              top    => $y,
              width  => $w,
              height => $h,
        maybe image  => $options{ image },
        maybe file   => $options{ file },
        maybe center => $options{ center },
        maybe update => $options{ update },
    );
}

sub _rgb($r,$g,$b,$alpha=undef) {
    # The Loupedeck uses 5-6-5 16-bit color
    # The bits in the number are matched to
    # bits  0123456789012345
    # color bbbbbggggggrrrrr
    # the memory storage is little-endian
        my $bit =
          (((int $r >> 3) & 0x1f) << 11)
        + (((int $g >> 2) & 0x3f) << 5)
        + (((int $b >> 3) & 0x1f))
        ;

        #die sprintf "[%d,%d,%d] %d - %04x", $r,$g,$b, $bit, $bit;
        return pack 'v', $bit
};

sub _rgbRect($width,$height,$r,$g,$b) {
        _rgb($r,$g,$b) x ($width*$height)
}

# Used for determining the bit ordering for the screen
sub set_screen_bit_sequence( $self, $screen, $sequence, $left=0, $top=0, $width=undef,$height=undef ) {
        $width //= $HID::LoupedeckCT::screens{$screen}->{width};
        $height //= $HID::LoupedeckCT::screens{$screen}->{height};
        my $image = $sequence x ($width*$height);
        return $self->set_screen_bits( $screen, $image, $left, $top, $width, $height );
}

sub set_screen_bits( $self, $screen, $bits, $left=0, $top=0, $width=undef,$height=undef ) {
        $width //= $HID::LoupedeckCT::screens{$screen}->{width};
        $height //= $HID::LoupedeckCT::screens{$screen}->{height};
        my $payload = pack("n", $HID::LoupedeckCT::screens{$screen}->{id} ) . pack('nnnn', $left, $top, $width,$height);
        if( $screen eq 'wheel' ) {
            $payload .= "\0";
        };
        $payload .= $bits;
        say length($payload);
        return $self->send_command( 0xff10, $payload );
        #$self->redraw_screen($screen);
}

sub set_screen_color( $self, $screen, $r,$g,$b, $left=0, $top=0, $width=undef,$height=undef ) {
        $width //= $HID::LoupedeckCT::screens{$screen}->{width};
        $height //= $HID::LoupedeckCT::screens{$screen}->{height};
        my $image = _rgbRect( $width,$height, $r,$g,$b );
        return $self->set_screen_bits( $screen, $image, $left, $top, $width, $height );
}

sub update_screen( $self, $top=0, $left=0, $width=undef,$height=undef ) {
        $width //= 15;
        $height //= 15;
        my $screen = 'middle';
        #my $payload = "\x00\x57\x00\x00\x00\x00" . "\x00\x3c\x01\x0e" # . pack('nn', $width,$height)

        #my $image = join "", map { _rgb(255,0,0) } 1..($width*$height);
        my $image = _rgbRect( $width,$height, 255,0,0 );
        #warn "$screen ($left,$top : ${width}x$height)";
        return $self->set_screen_bits( $screen, $image, $left, $top, $width, $height );
}

1;

=head1 SEE ALSO

L<https://github.com/bitfocus/loupedeck-ct/blob/master/index.js>

L<https://github.com/CommandPost/CommandPost/blob/develop/src/extensions/hs/loupedeck/init.lua>

=cut
