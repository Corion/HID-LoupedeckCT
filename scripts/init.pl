#!perl
use strict;
use 5.020;
use experimental 'signatures';
use Mojo::UserAgent;
use Mojo::WebSocket qw(WS_PING);
use Getopt::Long;
use Pod::Usage;

use IO::Interface::Simple; # for autodetection of the Loupedeck CT network "card"

my $ua = Mojo::UserAgent->new(
);
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

my $highlight = 7;

my @forever;

my ($drawtop, $drawleft) = (0,0);

my $w = $ua->websocket($url => sub {
    my ($ua, $tx) = @_;
    say 'WebSocket handshake failed!' and return unless $tx->is_websocket;
    $tx->on(binary => sub {
      my ($tx, $data) = @_;

	  use Data::Dumper;
	  #$Data::Dumper::Useqq = 1; warn Dumper $data;
      # Dispatch it, if we have a receiver for it:
      my @res = unpack 'ncca*', $data;
      my %res = (
          code     => $res[0],
          code_vis => sprintf( '%04x', $res[0] ),
          id     => $res[1],
          status => $res[2],
          payload => $res[3],
      );
      warn Dumper \%res;

      if( $res{ code } == 0x0501 ) {
		  use Data::Dumper;
		  warn Dumper $res{ payload };
		  if( $res{ payload } eq "\1" ) {
			if( $res{ status } == 5 ) { $drawtop++ }
			elsif( $res{ status } == 4 ) { $drawleft++ };
		  } else {
			if( $res{ status } == 5 ) { $drawtop-- }
			elsif( $res{ status } == 4 ) { $drawleft-- };
		  };
		  update_screen($tx, $drawtop, $drawleft);
	  };

      my $id = ord(substr($data,0,1));
      if( my $cb = delete $callbacks{ $id }) {
		  $cb->( \%res, $data );
	  };
    });

    push @forever, Mojo::IOLoop->recurring( 10 => sub {
		$tx->send([1, 0, 0, 0, WS_PING, 'ping']);
	});

	push @forever, Mojo::IOLoop->recurring( 5 => sub {
		button_color($tx,$highlight,0,0,0);
		$highlight = ((($highlight-7)+1)%20)+7;
		button_color($tx,$highlight,127,127,127);
	});

    #$tx->send({json => {msg => 'Hello World!'}});
    initialize($tx);
    #redraw_screen($tx,"wheel");
    #redraw_screen($tx,"middle");
    button_color($tx,7,0,0,0);
    #update_screen($tx);
});

sub initialize( $tx ) {
    #$tx->send({ binary => "\x04\x09\x0b\x03" });
    $tx->send({ binary => "\x04\x09\x00\x09" }); # reset
    set_screen_color($tx,'left',0,0,0);
    set_screen_color($tx,'middle',0,0,0);
    set_screen_color($tx,'right',0,0,0);
    set_screen_color($tx,'wheel',0,0,0);
};

our %screens = (
    left   => { id => 0x004c, width =>  60, height => 270, },
    middle => { id => 0x0041, width => 360, height => 270, },
    right  => { id => 0x0052, width =>  60, height => 270, },
    wheel  => { id => 0x0057, width => 240, height => 240, },
);

sub send_command( $tx, $command, $cbid, $payload ) {
	$cbid ||= chr(0);
	my $p = pack( "n", $command) . "$cbid$payload";
	#use Data::Dumper;
	#$Data::Dumper::Useqq = 1; warn Dumper $p;
    $tx->send({ binary => $p });
}

sub redraw_screen( $tx, $screen ) {
	my $cbid = chr(0);
	warn "Redrawing '$screen'";
    #send_command( $tx, 0x050f, undef, "\x0b\x03" . pack("n", $screens{$screen}->{id} ));
    send_command( $tx, 0x050f, undef, pack("n", $screens{$screen}->{id} ));
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
	my $cbid = chr(0);
	$width //= $screens{$screen}->{width};
	$height //= $screens{$screen}->{height};
	#my $screen = 'middle';
	#my $payload = "\x00\x57\x00\x00\x00\x00" . "\x00\x3c\x01\x0e" # . pack('nn', $width,$height)

	#my $image = join "", map { _rgb(255,0,0) } 1..($width*$height);
	my $image = _rgbRect( $width,$height, $r,$g,$b );
	my $payload = pack("n", $screens{$screen}->{id} ) . pack('nnnn', $left, $top, $width,$height)
	    . $image;
	send_command( $tx, 0xff10, undef, $payload );
	redraw_screen($tx, $screen);
}

sub update_screen( $tx, $top=0, $left=0, $width=undef,$height=undef ) {
	my $cbid = chr(0);
	$width //= 15;
	$height //= 15;
	my $screen = 'middle';
	#my $payload = "\x00\x57\x00\x00\x00\x00" . "\x00\x3c\x01\x0e" # . pack('nn', $width,$height)

	#my $image = join "", map { _rgb(255,0,0) } 1..($width*$height);
	my $image = _rgbRect( $width,$height, 255,0,0 );
	#warn "$screen ($left,$top : ${width}x$height)";
	my $payload = pack("n", $screens{$screen}->{id} ) . pack('nnnn', $left, $top, $width,$height)
	    . $image;
	send_command( $tx, 0xff10, undef, $payload );
	redraw_screen($tx, $screen);
}

    # round buttons: 7 to 14
    # square buttons: 15 to 26
sub button_color( $tx, $button, $r, $g, $b ) {
	my $cbid = chr(0);
	my $payload = pack "cccc", $button, $r, $g, $b;
	send_command( $tx, 0x0702, undef, $payload );
}

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
