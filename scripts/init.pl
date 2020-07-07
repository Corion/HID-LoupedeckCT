#!perl
use strict;
use 5.020;
use experimental 'signatures';

use Getopt::Long;
use Pod::Usage;
use PerlX::Maybe;

use Imager;

use HID::LoupedeckCT;

GetOptions(
    'uri=s' => \my $uri,
) or pod2usage(2);


my %callbacks;
my $cbid = 1;

my $highlight = 7;
my $brightness;
my $bit_offset = 0;
my $white_bits = 1;
my $r_bits = 1;
my $g_bits = 1;
my $b_bits = 1;

my @forever;

my ($drawtop, $drawleft) = (100,100);

sub clamp($value_ref, $min, $max) {
    if( $$value_ref < $min ) {
        $$value_ref = $min
    } elsif( $$value_ref > $max ) {
        $$value_ref = $max
    }
};

sub clamp_v($value, $min, $max) {
    my $res = $value;
    clamp(\$res, $min, $max);
    return $res
};

#my $bit = unpack 'v', _rgb(255,255,255);
#warn sprintf "[%d,%d,%d] %d - %016b", 255,255,255, $bit, $bit;
#my $bit = unpack 'v', _rgb(127,127,127);
#warn sprintf "[%d,%d,%d] %d - %016b", 127,127,127, $bit, $bit;
#my $bit = unpack 'v', _rgb(63,63,63);
#warn sprintf "[%d,%d,%d] %d - %016b", 63,63,63, $bit, $bit;
#die;

my $image = Imager->new( file => '/home/corion/Bilder/IMG_20190629_110236.jpg');
my $image2 = Imager->new( file => '/run/user/1000/gvfs/smb-share:server=aliens,share=media-pub/mp3/Cafe del Mar/Various Artists - Best Of Del Mar, Vol. 9 Beautiful Chill Sounds/1165921.jpg');

my $ld = HID::LoupedeckCT->new();
say "Connecting to " . $ld->uri;
$ld->on('turn' => sub($ld,$info) {
          my %dirty;

          my $knob = $info->{id};
          my $direction = $info->{direction};
          if   ( $knob == 0 ) { $brightness += $direction; }
          elsif( $knob == 1 ) { $brightness += $direction }
          elsif( $knob == 2 ) { $bit_offset += $direction; $dirty{middle}=1 }
          elsif( $knob == 3 ) { $white_bits += $direction; $dirty{middle}=1 }
          elsif( $knob == 4 ) { $r_bits += $direction; $dirty{right}=1 }
          elsif( $knob == 5 ) { $g_bits += $direction; $dirty{right}=1 }
          elsif( $knob == 6 ) { $b_bits += $direction; $dirty{right}=1 }
          #elsif( $knob == 5 ) { $drawtop += $direction }
          #elsif( $knob == 4 ) { $drawleft += $direction }
          else {
              # unmapped knob
          };

          clamp( \$brightness, 0, 10 );
          clamp( \$bit_offset, 0, 15 );
          clamp( \$white_bits, 1, 8 );
          clamp( \$r_bits, 1, 8 );
          clamp( \$g_bits, 1, 8 );
          clamp( \$b_bits, 1, 8 );

          #update_screen($ld);
          $ld->set_backlight_level($brightness)->retain;

          if( $dirty{ middle }) {
              set_screen_bit_sequence($ld,'middle', pack( 'v', 1 << $bit_offset), 0,0,180,180)->retain;
          };
          #set_screen_bit_sequence($ld,'wheel', pack( 'v', 1 << $bit_offset), 0,0,180,180)->retain;
          my $w = (1 << $white_bits) -1;
          if( $dirty{ left }) {
              set_screen_color($ld,'left', $w,$w,$w)->retain;
          };

          my $r = (1 << $r_bits) -1;
          my $g = (1 << $g_bits) -1;
          my $b = (1 << $b_bits) -1;
          if( $dirty{ right }) {
              set_screen_color($ld,'right', $r,$g,$b)->retain;
          };

          for (sort keys %dirty) {
              $ld->redraw_screen($_)->retain;
          };
});

my %toggles;

$ld->on('key' => sub($ld,$info) {
    say sprintf "Key event: id: %d, released: %d", $info->{id}, $info->{released};
    my $key = $info->{id};
    if( $key >= 7 and $key <= 26 and $info->{released}) {
        my $onoff = $toggles{ $key } ^= 1;
        $ld->set_button_color($key, 127*$onoff, 127*$onoff, 64*$onoff )->retain;
    };
});

#$ld->on('wheel' => sub($ld,$info) {
#    say sprintf "Wheel event: id: %d, released: %d", $info->{id}, $info->{released};
#});

$ld->on('touch' => sub($ld,$info) {
    if( defined $info->{button} ) {
        my @r = $ld->button_rect( $info->{button});
        my ($screen,$x,$y,$w,$h) = @r;
        my $rel = !$info->{released};
	load_image_button($ld,image => $image2, button => $info->{button}, center => 1,update => 1)->retain;
        #set_screen_color($ld,$screen,127*$rel,127*$rel,127*$rel,$x,$y,$w,$h)->then(sub {
        #    $ld->redraw_screen($screen)
        #})->retain;
    };
    say sprintf "Touch event: id: %d, released: %d, finger: %d, (%d,%d)", $info->{button}, $info->{released}, $info->{finger}, $info->{x}, $info->{y};
});

$ld->on('wheel_touch' => sub($ld,$info) {
    #my @r = $ld->button_rect( $info->{button});
    my ($screen,$x,$y,$w,$h) = ('wheel', 0,0,240,240);
    my $rel = !$info->{released};
    set_screen_color($ld,'wheel',0,0,127*$rel,$x,$y,$w,$h)->then(sub {
        $ld->redraw_screen('wheel')
    })->retain;
    say sprintf "Touch event: released: %d, finger: %d, (%d,%d)", $info->{released}, $info->{finger}, $info->{x}, $info->{y};
});


$ld->connect()->then(sub {;
    initialize($ld);
})->retain;

sub initialize( $self ) {
    $ld->restore_backlight_level->retain;
    # We could be a bit more specific, but why bother ;)
    for my $id (7..31) {
        $ld->set_button_color($id,0,0,0)->retain;
    };

    # set up our neat "UI"
    $ld->get_backlight_level->then(sub($val) {
        $brightness = $val;
    })->retain;
        $ld->get_serial_number->then(sub(%versions) {
            use Data::Dumper; warn Dumper \%versions;
        })->retain;
        $ld->get_firmware_version->then(sub(%versions) {
            use Data::Dumper; warn Dumper \%versions;
        })->retain;
        #push @stuff, read_register($ld,0);
        #push @stuff, read_register($ld,1);
        #$ld->read_register(2)->retain;
        #push @stuff, read_register($ld,3);
        #push @stuff, read_register($ld,4);
        #$ld->set_register(2,0x02000819)->retain;
        #push @stuff, set_register($ld,2, );
        #push @stuff, button_color($ld, 7,127,127,0);
    set_screen_color($ld,'left',0,0,0)->retain;
    set_screen_color($ld,'middle',0,0,0)->retain;
    set_screen_color($ld,'right',0,0,0)->retain;
    set_screen_color($ld,'wheel',0,0,0)->retain;
    load_image_button( $ld, image => $image, button => 3, center => 1, update => 1, )->retain;
    load_image( $ld, screen => 'wheel', center => 1, image => $image, update => 1, )->retain;
    #my @bits = map { pack 'n', $_ } (
    #    #0b0000000000000001, # g
    #    #0b0000000000000010, # g
    #    #0b0000000000000100, # g
    #    #0b0000000000001000, # ?
    #
    #    0b0000000000010000, #r ?
    #    0b0000000000100000, #r
    #    0b0000000001000000, #r
    #    0b0000000010000000, #r
    #
    #    0b0000000100000000, # b?
    #    0b0000001000000000, # b
    #    0b0000010000000000, # b
    #    0b0000100000000000, # b
    #
    #    0b0001000000000000, # b
    #    0b0010000000000000,
    #    0b0100000000000000,
    #    0b1000000000000000,
    #);

    #for my $row (0,1,2) {
        #for my $col (0,1,2,3) {
        #    my $left = $col * 90;
        #    my $top  = $row * 90;
        #    #warn "[$r,$g,$b]";
        #    set_screen_bits($ld,'middle', $bits[$row*4+$col], $left, $top, 90,90)->retain;
        #};
    #};
            #exit;
    #set_screen_color($ld,'middle',255,0,0,  0,0, 90,90);
    #set_screen_color($ld,'middle',0,255,0, 89,89,90,90);
    #set_screen_color($ld,'middle',0,0,255, 180,180,90,90);

};

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
        return set_screen_bits( $self, $screen, $image, $left, $top, $width, $height );
}

sub set_screen_bits( $self, $screen, $bits, $left=0, $top=0, $width=undef,$height=undef ) {
        $width //= $HID::LoupedeckCT::screens{$screen}->{width};
        $height //= $HID::LoupedeckCT::screens{$screen}->{height};
        my $payload = pack("n", $HID::LoupedeckCT::screens{$screen}->{id} ) . pack('nnnn', $left, $top, $width,$height);
        if( $screen eq 'wheel' ) {
            $payload .= "\0";
        };
        $payload .= $bits;
        return $self->send_command( 0xff10, $payload );
        #$self->redraw_screen($screen);
}

sub set_screen_color( $self, $screen, $r,$g,$b, $left=0, $top=0, $width=undef,$height=undef ) {
        $width //= $HID::LoupedeckCT::screens{$screen}->{width};
        $height //= $HID::LoupedeckCT::screens{$screen}->{height};
        my $image = _rgbRect( $width,$height, $r,$g,$b );
        return set_screen_bits( $self, $screen, $image, $left, $top, $width, $height );
}

sub update_screen( $self, $top=0, $left=0, $width=undef,$height=undef ) {
        $width //= 15;
        $height //= 15;
        my $screen = 'middle';
        #my $payload = "\x00\x57\x00\x00\x00\x00" . "\x00\x3c\x01\x0e" # . pack('nn', $width,$height)

        #my $image = join "", map { _rgb(255,0,0) } 1..($width*$height);
        my $image = _rgbRect( $width,$height, 255,0,0 );
        #warn "$screen ($left,$top : ${width}x$height)";
        return set_screen_bits( $self, $screen, $image, $left, $top, $width, $height );
}

sub load_image_button( $self, %options ) {
    my $button = delete $options{ button };

    my @r = $ld->button_rect( $button);
    my ($screen,$x,$y,$w,$h) = @r;

    return load_image(
        $ld,
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

sub load_image( $self, %options ) {
    # load the image
    $options{ image } //= Imager->new( file => delete $options{ file });
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

    my $res = set_screen_bits($ld, $screen, $image_bits, $x, $y, $img->getwidth,$img->getheight);
    if( $options{ update }) {
	$res = $res->then(sub {
	    $self->redraw_screen( $screen );
	});
    };
    return $res
}

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
