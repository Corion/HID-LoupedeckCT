package HID::LoupedeckCT 0.01;
use strict;
use warnings;

use 5.020;

use Mojo::UserAgent;
use Mojo::WebSocket qw(WS_PING);
use Mojo::Base 'Mojo::EventEmitter';

use Moo 2;

use IO::Interface::Simple; # for autodetection of the Loupedeck CT network "card"

use Future::Mojo;

use experimental 'signatures';
no warnings 'experimental';

=head1 NAME

HID::LoupedeckCT - Perl driver for the Loupedeck CT keyboard

=head1 SYNOPSIS

=cut

has 'uri' => (
    is => 'lazy',
    default => \&_build_uri,
);

has 'ua' => (
    is => 'lazy',
    default => sub {
        Mojo::UserAgent->new();
    },
);

has 'tx' => (
    is => 'ro',
);

has 'callbacks' => (
    is => 'lazy',
    default => sub { +{} },
);

has '_cbid' => (
    is => 'rw',
    default => 0,
);

has '_ping' => (
    is => 'ro',
);

=head1 METHODS

=over 4

=cut

sub get_cbid( $self ) {
	my $res = $self->_cbid;
	$self->_cbid( ($res+1)%256 );
	$res
}

sub list_loupedeck_devices {
    return map {
        $_->address =~ m/^(100\.127\.\d+)\.2$/
        ? "$1.1"
        : ()
    } IO::Interface::Simple->interfaces;
}

sub _build_uri {
    (my $uri) = __PACKAGE__->list_loupedeck_devices();
    return $uri
}

sub send_command( $self, $command, $payload ) {
    my $tx = $self->tx;
    my $cbid = $self->get_cbid;
    $self->callbacks->{ $cbid } = my $res = Future::Mojo->new($self->ua->ioloop);
    #warn "Installed callback $cbid";
    my $p = pack( "nC", $command, $cbid) . $payload;
    $self->hexdump('> ',$p);

    $tx->send({ binary => $p });
    return $res;
}

sub hexdump( $self, $prefix, $str ) {
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

our %screens = (
    left   => { id => 0x004c, width =>  60, height => 270, },
    middle => { id => 0x0041, width => 360, height => 270, },
    right  => { id => 0x0052, width =>  60, height => 270, },
    wheel  => { id => 0x0057, width => 240, height => 240, },
);

# Touch coordinates, not pixel coordinates!
our @buttons = (
    # id, xl, yl, xr, yr
    [  0,  15, 15, 60, 260 ],

    [  1,  80, 15, 145, 90 ],
    [  2, 165, 15, 235, 90 ],
    [  3, 250, 15, 320, 90 ],
    [  4, 335, 15, 410, 90 ],

    [  5,  80, 105, 145, 175 ],
    [  6, 165, 105, 235, 175 ],
    [  7, 250, 105, 320, 175 ],
    [  8, 335, 105, 410, 175 ],

    [  9,  80, 190, 145, 260 ],
    [ 10, 165, 190, 235, 260 ],
    [ 11, 250, 190, 320, 260 ],
    [ 12, 335, 190, 410, 260 ],

    [ 13, 425,  15, 470, 260 ],
);

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

# Simple linear search through our list...
sub button_rect( $self, $button ) {
	if( $button == 0 ) {
		return ('left', 0,0,$screens{left}->{width},$screens{left}->{height});
	} elsif( $button == 13 ) {
		return ('right', 0,0,$screens{right}->{width},$screens{right}->{height});
	} else {
		my $x = int( ($button-1)%4)*90;
		my $y = int( ($button-1)/4)*90;

		return ('middle',$x,$y,$x+90,$y+90);
	}
};

sub connect( $self, $uri = $self->uri ) {
	my $res = Future::Mojo->new(
	    $self->ua->ioloop,
	);
    my $tx = $self->ua->websocket_p($uri)->then(sub {
        my ($tx) = @_;
        say 'WebSocket handshake failed!' and return unless $tx->is_websocket;
        $self->{tx} = $tx;
        $res->done($self);
        $tx->on(binary => sub {
			my ($tx, $raw) = @_;

			$self->hexdump('< ',$raw);
			# Dispatch it, if we have a receiver for it:
			my @res = unpack 'nCa*', $raw;
			my %res = (
				code     => $res[0],
				code_vis => sprintf( '%04x', $res[0] ),
				cbid   => $res[1],
				data => $res[2],
			);

			my $id = $res{ cbid };
			my $f = delete $self->callbacks->{ $id };
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
		});

        $self->{_ping} = Mojo::IOLoop->recurring( 10 => sub {
            $tx->send([1, 0, 0, 0, WS_PING, 'ping']);
        });
	});
	$res
};

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

sub set_register( $self, $register, $value ) {
    my $update = pack 'CN', $register, $value;
    return $self->send_command(0x0819, $update)
}

sub get_backlight_level( $self ) {
    return $self->read_register(2)->then(sub(%result) {
        my $val = ($result{value} & 0x0000ff00) >> 8;
        return Future::Mojo->done($val);
    });
}

sub set_backlight_level( $self, $level ) {
    # Store the persistent backlight level
    return $self->read_register(2)->then(sub(%result) {
        my $val = ($result{value} & 0x0000ff00) >> 8;
        warn "Backlight level is $val, setting to $level";
        if( $val != $level ) {
            $result{ value } = ($result{value} & 0xffff00ff) | ($level << 8);
            return $self->set_register(2, $result{value});
        } else {
            return Future::Mojo->done;
        };
    })->then(sub {
		$self->send_command(0x0409,chr($level))
    });;
}

sub restore_backlight_level( $self ) {
    return get_backlight_level($self)->then(sub($level) {
		return set_backlight_level($self,$level);
    });
}

sub vibrate( $self, $sequence ) {
    return $self->send_command(0x041B, chr($sequence))
}

=item *

Enables or disables the built-in flash drive

You might need to unplug and replug the device to get the flash drive
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

sub get_wheel_sensitivity( $self ) {
    return $self->send_command(0x041e,"\0")->then(sub($info,$data) {
        my $val = unpack 'C', $data;
        return Future::Mojo->done($val);
    });
}

sub redraw_screen( $self, $screen ) {
        #warn "Redrawing '$screen'";
    #$self->send_command( 0x050f, undef, "\x0b\x03" . pack("n", $screens{$screen}->{id} ));
    $self->send_command( 0x050f, pack("n", $screens{$screen}->{id} ));
};

    # round buttons: 7 to 14
    # square buttons: 15 to 26
sub set_button_color( $self, $button, $r, $g, $b ) {
    my $payload = pack "cccc", $button, $r, $g, $b;
    $self->send_command( 0x0702, $payload );
}

1;

=back

=head1 SEE ALSO

L<https://github.com/bitfocus/loupedeck-ct/blob/master/index.js>

L<https://github.com/CommandPost/CommandPost/blob/develop/src/extensions/hs/loupedeckct/init.lua>

=cut
