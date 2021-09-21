package Assistant::Timers;
use strict;
use warnings;
use 5.012;

use Moo 2;

use experimental 'signatures';

has 'start_epoch' => (
    is => 'rw',
);

has 'duration' => (
    is => 'rw',
);

has 'original_duration' => (
    is => 'rw',
);

#             stopped <---------------+----+
#            /                         \    \
#       ->start()                         \    \
#          /                                \    \
#     running        ->pause() -> paused ->stop() \
#              <-    ->unpause()                   \
#                    ->stop()    ------->-----------+
#                                                    \
#                                                     \
#                                               ->restart()
#

has 'state' => (
    is => 'rw',
);

sub BUILDARGS($self, @args) {
    my $args = $args[0];
    if( ! ref $args) {
        $args = { @args };
    };
    $args->{original_duration} //= $args->{duration};
    $args->{state} //= 'stopped';
    return $args;
};

sub end_epoch( $self, $from=time() ) {
    my $start = $self->start_epoch // $from;
    return $start + $self->duration
}

sub start( $self, $reference=time() ) {
    $self->start_epoch( $reference );
    $self->state('running');
}

sub stop( $self, $reference=time() ) {
    $self->original_duration( undef );
    $self->start_epoch( undef );
    $self->state('stopped');
}

sub started( $self ) {
    $self->state =~ /^(running|paused)$/;
}

sub expired( $self, $reference=time() ) {
        $self->state eq 'running'
    and $reference >= $self->end_epoch
}

sub stopped( $self, $reference=time()) {
       $self->state eq 'stopped'
    or $self->expired
}

sub paused( $self ) {
    $self->state eq 'paused'
}

sub remaining( $self, $reference=time() ) {
    return undef unless $self->started;
    return 0 if $self->expired;
    return $self->end_epoch - $reference
}

sub pause( $self, $reference=time() ) {
    $self->duration( $self->remaining );
    $self->start_epoch(undef);
    $self->state('paused');
}

sub unpause( $self, $reference=time() ) {
    $self->start($reference);
}

sub restart( $self, $reference=time() ) {
    $self->duration( $self->original_duration );
    $self->start;
}

1;
