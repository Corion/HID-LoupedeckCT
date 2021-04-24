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
    'image-dir=s' => \my $image_dir,
) or pod2usage(2);

$image_dir //= '.';

my $highlight = 7;
my $brightness;
my $bit_offset = 0;
my $white_bits = 1;
my $r_bits = 1;
my $g_bits = 1;
my $b_bits = 1;

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

my $image = Imager->new( file => "$image_dir/IMG_8395.JPG");
my $image2 = Imager->new( file => "$image_dir/IMG_8395.JPG");

my $ld = HID::LoupedeckCT->new(
    maybe uri => $uri,
);
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
	$ld->load_image_button(image => $image2, button => $info->{button}, center => 1,update => 1)->retain;
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

$ld->on('hexdump' => sub {
#use Data::Dumper; warn Dumper \@_;
eval {
    my ($ld, $prefix,$line) = @_;
    say $prefix . $line;
    }; warn $@ if $@;
});

$ld->connect()->then(sub {;
    initialize($ld);
})->retain;

sub initialize( $self ) {
    $ld->get_self_test->retain;
    $ld->get_mcu_id->then(sub($id) {
        say "MCU id: $id";
    })->retain;

# No reply for 0x0305, 0x0306, 0x0308
# unknown request/response 0x131c
# some checksum?
#$ld->send_command(0x131c,'\xB2\xC6\xA3\x1D\x3A\xF7\xD9\x85\xE0\x21\x2D\x2D\x87')->then(sub($info,$data) {
#    say "131c";
#    use Data::Dumper;
#    warn Dumper $info->{data};
#    exit;
#})->retain;

    $ld->restore_backlight_level->retain;
    # We could be a bit more specific, but why bother ;)
    for my $id (7..31) {
        $ld->set_button_color($id,0,0,0)->retain;
    };

    $ld->get_wheel_sensitivity()->then(sub($sensitivity) {
        say "Wheel sensitivity: $sensitivity";
    })->retain;

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
    $ld->load_image_button( image => $image, button => 3, center => 1, update => 1, )->retain;
    $ld->load_image( screen => 'wheel', center => 1, image => $image, update => 1, )->retain;
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

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
