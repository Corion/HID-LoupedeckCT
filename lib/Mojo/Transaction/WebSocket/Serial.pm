package Mojo::Transaction::WebSocket::Serial;
#use Mojo::Base 'Mojo::Transaction::WebSocket';
use Mojo::Base 'Mojo::EventEmitter';
use Mojo::WebSocket 'WS_PING', 'WS_PONG', 'WS_TEXT', 'WS_BINARY', 'WS_CLOSE';
use Future::Mojo;
use Encode 'encode';

use Fcntl;
use MIME::Base64 'encode_base64';

use Carp 'croak';

# https://www.perlmonks.org/?node_id=11114488

use Data::Dumper;

has 'name';
has 'stream';
has 'on_close';
has max_websocket_size => sub { $ENV{MOJO_MAX_WEBSOCKET_SIZE} || 262144 };

sub masked { 1 }; # we are the "client"
sub compressed { 0 }; # no compression

sub _open_serial_other {
	my( $self, $portname ) = @_;
	require IO::Termios;

    sysopen my $fh, $portname, O_RDWR
        or die "sysopen '$portname': $!";
    binmode $fh; # just to be certain
    my $handle = IO::Termios->new($fh) or die "IO::Termios->new: $!";
    $handle->set_mode('9600,8,n,2');
    $handle->cfmakeraw;
	return $handle
}

sub _open_serial_win32 {
	my( $self, $portname ) = @_;
	require Win32::SerialPort;

	require File::Temp;
	my( $fh, $tmpname ) = File::Temp::tempfile();
	close $fh;

	my $port = Win32::SerialPort->new($portname)
	    or croak "CanÄt open '$portname': $^E";
	$port->baudrate(9600);
	$port->bits(8);
	$port->stopbits(1);
	$port->write_settings;
	$port->save( $tmpname );

	local *FH;
	$port = tie *FH, 'Win32::SerialPort', $tmpname;
    binmode $fh; # just to be certain
	return $fh
}

sub open_p {
    my( $self ) = @_;

    my $res = Future::Mojo->new(Mojo::IOLoop->new);

    my $fn = $self->name;
	my $serial = $^O =~ /mswin/i ? '_open_serial_win32' : '_open_serial_other';
	my $handle = $self->$serial( $fn );
    my $h = Mojo::IOLoop::Stream->new($handle);
    $self->stream($h);

    my $read_buffer;
    $h->on(read => sub {
        my ($h, $raw) = @_;

        $read_buffer .= $raw;
        #say sprintf "Read buffer %d bytes", length($read_buffer);
        #use Data::Dumper; $Data::Dumper::Useqq = 1;
        #warn "<" . Dumper $read_buffer;

        # If we're still initializing the WS, don't trigger other events
        # We should check the challenge/response handshake ...

        if( ! $self->{_switched_to_websocket}) {
            #say "***";
            #$self->hexdump('< ',$read_buffer);
            if( $read_buffer =~ s!\A(HTTP/1.1 101.*\r\n\r\n)!!s ) {
                $self->{_switched_to_websocket} = 1;
                #say "Switched to WS";
                #say "Connected to LD via WS-over-serial";

                # Launch our keep-alive ping
                $self->{_ping} = Mojo::IOLoop->recurring( 5 => sub {
                    $self->send([1,0,0,0,WS_PING,''] );
                });
                $res->done($self);
            } else {
                #say "Waiting for complete response";

                return;
            };
        };
        if( ! length $read_buffer) {
            #say "Nothing read, nothing to do";
        } else {
            # We're talking Websocket-over-serial now:
            my $max = $self->max_websocket_size;
            while (my $frame = Mojo::WebSocket::parse_frame(\$read_buffer, $max)) {
                $self->finish(1009) and last unless ref $frame;
                $self->on_ws_frame($frame);
            }
        };
    });

    $h->on( close => sub {
        #say "LD $fn has gone away, reconnecting...";
        my $c = $self->on_close;
        if( $c ) {
            eval { $c->($self) }
        };
    });

    $h->on( error => sub {
        my ( $h, $error ) = @_;
        say "LD $fn has error '$error'";
    });

    #$h->on(write => sub {
    #    $self->server_write;
    #});

    $h->start;
    say "Writing request to $h";

    # This should be something more random, and we should also check
    # the challenge...
    my $ws_key = encode_base64('the sample nonce');
    $ws_key =~ s!\s+!!g;

    my $ws_startup = <<"HTTP";
GET /index.html HTTP/1.1
Sec-WebSocket-Key: $ws_key
Connection: Upgrade
Upgrade: websocket
HTTP

    $ws_startup =~ s!\s*\x0a!\x0d\x0a!sg;
    $h->write($ws_startup."\x0d\x0a");

    return $res;
}

# cf Mojo::Transaction::WebSocket
sub on_ws_frame {
    my ( $self, $frame ) = @_;
  # Ping/Pong
  my $op = $frame->[4];
  return $self->send([1, 0, 0, 0, WS_PONG, $frame->[5]]) if $op == WS_PING;
  return undef                                           if $op == WS_PONG;

  $self->{message} .= $frame->[5];
  my $max = $self->max_websocket_size;
  return $self->finish(1009) if length $self->{message} > $max;
  return undef unless $frame->[0];

  my $msg = delete $self->{message};
  $self->emit($op == WS_TEXT ? 'text' : 'binary' => $msg);
}

sub build_message {
  my ($self, $frame) = @_;

  # Text
  $frame = {text => encode('UTF-8', $frame)} if ref $frame ne 'HASH';

  # JSON
  $frame->{text} = encode_json($frame->{json}) if exists $frame->{json};

  # Raw text or binary
  if   (exists $frame->{text}) { $frame = [1, 0, 0, 0, WS_TEXT,   $frame->{text}] }
  else                         { $frame = [1, 0, 0, 0, WS_BINARY, $frame->{binary}] }

  # "permessage-deflate" extension
  #return $frame unless $self->compressed;
  #my $deflate = $self->{deflate}
  #  ||= Compress::Raw::Zlib::Deflate->new(AppendOutput => 1, MemLevel => 8, WindowBits => -15);
  #$deflate->deflate($frame->[5], my $out);
  #$deflate->flush($out, Z_SYNC_FLUSH);
  #@$frame[1, 5] = (1, substr($out, 0, length($out) - 4));

  return $frame;
}

sub send {
    my ($self, $msg, $cb ) = @_;

    #$self->stream->once( drain => $cb ) if $cb;
    #$self->once(drain => $cb) if $cb;

    $msg = $self->build_message($msg) unless ref $msg eq 'ARRAY';
    my $payload = Mojo::WebSocket::build_frame($self->masked, @$msg);

    #use Data::Dumper; $Data::Dumper::Useqq = 1;
    #say "Write " . Dumper $payload;

    $self->stream->write($payload);

    #return $self->emit('resume');
    return $self
}

#sub resume {
#    my( $self ) = @_;
#    if( my $write = delete $self->{write}) {
#        say "Writing on resume";
#        $self->stream->write( $write );
#    }
#}


sub finish {
  my $self = shift;

  my $close   = $self->{close} = [@_];
  my $payload = $close->[0] ? pack('n', $close->[0]) : '';
  $payload .= encode 'UTF-8', $close->[1] if defined $close->[1];
  $close->[0] //= 1005;
  $self->send([1, 0, 0, 0, WS_CLOSE, $payload])->{closing} = 1;

  return $self;
}

1;
