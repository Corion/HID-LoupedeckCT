#!perl
use strict;
use 5.020;
use experimental 'signatures';

use Getopt::Long;
use Pod::Usage;

use Imager;

use HID::LoupedeckCT;

GetOptions(
    'uri=s' => \my $uri,
) or pod2usage(2);


my %callbacks;
my $cbid = 1;

my $highlight = 7;
my $brightness;

my @forever;

my ($drawtop, $drawleft) = (100,100);

sub clamp($value_ref, $min, $max) {
    if( $$value_ref < $min ) {
	$$value_ref = $min
    } elsif( $$value_ref > $max ) {
	$$value_ref = $max
    }
};

my $ld = HID::LoupedeckCT->new();
$ld->on('turn' => sub($ld,$info) {
          my $knob = $info->{id};
	  my $direction = $info->{direction};
          if   ( $knob == 5 ) { $drawtop += $direction }
	  elsif( $knob == 4 ) { $drawleft += $direction }
	  elsif( $knob == 1 ) { $brightness += $direction }

	  clamp( \$brightness, 0, 10 );

	  $ld->set_backlight_level($brightness)->retain;
});

$ld->connect()->then(sub {;
    warn "Connected";
    initialize($ld);
})->retain;

sub initialize( $self ) {
    $ld->restore_backlight_level->retain;
    $ld->get_backlight_level->then(sub($val) {
	$brightness = $val;
    })->retain;
        #push @stuff, get_backlight_level($ld);
        #push @stuff, set_flashdrive($ld,1);
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
    #set_screen_color($ld,'left',0,0,0);
    #set_screen_color($ld,'middle',0,0,0);
    #set_screen_color($ld,'right',0,0,0);
    #set_screen_color($ld,'wheel',0,0,0);

};

our %screens = (
    left   => { id => 0x004c, width =>  60, height => 270, },
    middle => { id => 0x0041, width => 360, height => 270, },
    right  => { id => 0x0052, width =>  60, height => 270, },
    wheel  => { id => 0x0057, width => 240, height => 240, },
);

sub redraw_screen( $self, $screen ) {
        #warn "Redrawing '$screen'";
    #$self->send_command( 0x050f, undef, "\x0b\x03" . pack("n", $screens{$screen}->{id} ));
    $self->send_command( 0x050f, pack("n", $screens{$screen}->{id} ));
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

sub set_screen_color( $self, $screen, $r,$g,$b, $top=0, $left=0, $width=undef,$height=undef ) {
        $width //= $screens{$screen}->{width};
        $height //= $screens{$screen}->{height};
        #my $screen = 'middle';
        #my $payload = "\x00\x57\x00\x00\x00\x00" . "\x00\x3c\x01\x0e" # . pack('nn', $width,$height)

        #my $image = join "", map { _rgb(255,0,0) } 1..($width*$height);
        my $image = _rgbRect( $width,$height, $r,$g,$b );
        my $payload = pack("n", $screens{$screen}->{id} ) . pack('nnnn', $left, $top, $width,$height);
        $payload .= $image;
        $self->send_command( 0xff10, $payload );
        redraw_screen($ld, $screen);
}

sub update_screen( $self, $top=0, $left=0, $width=undef,$height=undef ) {
        $width //= 15;
        $height //= 15;
        my $screen = 'middle';
        #my $payload = "\x00\x57\x00\x00\x00\x00" . "\x00\x3c\x01\x0e" # . pack('nn', $width,$height)

        #my $image = join "", map { _rgb(255,0,0) } 1..($width*$height);
        my $image = _rgbRect( $width,$height, 255,0,0 );
        #warn "$screen ($left,$top : ${width}x$height)";
        my $payload = pack("n", $screens{$screen}->{id} ) . pack('nnnn', $left, $top, $width,$height)
            . $image;
        $self->send_command( 0xff10, $payload );
        $self->redraw_screen($screen);
}

    # round buttons: 7 to 14
    # square buttons: 15 to 26
sub button_color( $self, $button, $r, $g, $b ) {
    my $payload = pack "cccc", $button, $r, $g, $b;
    $self->send_command( 0x0702, $payload );
}

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
