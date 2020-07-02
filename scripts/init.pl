#!perl
use strict;
use 5.020;
use experimental 'signatures';
use Mojo::UserAgent;
use Mojo::WebSocket qw(WS_PING);

my $url = 'ws://100.127.11.1/';

my $ua = Mojo::UserAgent->new();

my %callbacks;

$ua->websocket($url => sub {
    my ($ua, $tx) = @_;
    say 'WebSocket handshake failed!' and return unless $tx->is_websocket;
    $tx->on(binary => sub {
      my ($tx, $data) = @_;

	  use Data::Dumper;
	  #$Data::Dumper::Useqq = 1; warn Dumper $data;
      # Dispatch it, if we have a receiver for it:
      my @res = unpack 'ncca*', $data;
      my %res = (
          code   => $res[0],
          id     => $res[1],
          status => $res[2],
          payload => $res[3],
      );
      warn Dumper \%res;
      my $id = ord(substr($data,0,1));
      if( my $cb = delete $callbacks{ $id }) {
		  $cb->( \%res, $data );
	  };
    });

    $ua->ioloop->recurring( 10 => sub {
		$tx->send([1, 0, 0, 0, WS_PING, 'ping']);
	});

    #$tx->send({json => {msg => 'Hello World!'}});
    initialize($tx);
    reset_screen($tx,"wheel");
    #button_color($tx,15,127,127,127);
    button_color($tx,15,0,0,0);
    #update_screen($tx);
});

sub initialize( $tx ) {
    #$tx->send({ binary => "\x04\x09\x0b\x03" });
    $tx->send({ binary => "\x04\x09\x00\x09" }); # reset
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
	use Data::Dumper;
	$Data::Dumper::Useqq = 1; warn Dumper $p;
    $tx->send({ binary => $p });
}

sub reset_screen( $tx, $screen ) {
	my $cbid = chr(0);
	warn "Reset '$screen'";
    send_command( $tx, 0x050f, undef, "\x0b\x03" . pack("n", $screens{$screen}->{id} ));
};

sub update_screen( $tx ) {
	my $cbid = chr(0);
	my ($width, $height) = (60,270);
	my $payload = "\x00\x4c\x00\x00\x00\x00" . pack('nn', $width,$height)
	    . join "", "\xff\xff" x ($width*$height);
	send_command( $tx, 0xff10, undef, $payload );
}

sub button_color( $tx, $button, $r, $g, $b ) {
	my $cbid = chr(0);
	my $payload = pack "cccc", $button, $r, $g, $b;
	send_command( $tx, 0x0702, undef, $payload );
}

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
