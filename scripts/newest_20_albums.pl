#!perl
use 5.020;
use feature 'signatures';
no warnings 'experimental::signatures';
use Getopt::Long;
use HID::LoupedeckCT;
use File::MimeInfo::Applications; # well, for Windows, we'll need something else

use PerlX::Maybe;
use Mojo::Promise::Role::Futurify;
use Protocol::DBus::Client::Mojo; # for DBus actions, Linux - Windows comes later, if ever

# Required for unix FD support, so we can actually perform our tasks
# during/just before shutdown
use Socket::MsgHdr;

use lib '../Filesys-Scanner/lib';
use Filesys::Scanner;
use Audio::Directory;

our $VERSION = '0.01';

use POSIX 'strftime';
use Data::Dumper;

GetOptions(
    'c=i' => \my $count,
    'uri=s' => \my $uri,
);
$count //= 12;

# This works only for directories up to two levels deep, which just happens
# to be how I organize music albums, either "album/" or "artist/album"
# In both cases the (Unix) timestamp reflects whether a directory was added
my $scanner = Filesys::Scanner->new(
    count => $count,
    wanted => sub( $dir ) {
        $dir->contains_music()
    },
);

sub init_ld() {
    return HID::LoupedeckCT->new(
        maybe uri => $uri,
        verbose => 1,
    );
}
my $ld = init_ld();

my $dbus_system = Protocol::DBus::Client::Mojo::system();
my $dbus_session = Protocol::DBus::Client::Mojo::login_session();

say "Connecting to " . $ld->uri;

my @albums;

my (@mp3_actions) = mime_applications('audio/mpeg');
my (@pl_actions) = mime_applications('audio/x-mpegurl');

sub play_album( $album ) {
    if( my $pl = $album->playlist ) {
        say $pl_actions[1]->Name;
        $pl_actions[1]->run($pl->name);
    } else {
        my @files = sort map { $_->name } $album->music_files;
        my $first = shift @files;
        say $mp3_actions[2]->Name;
        $mp3_actions[1]->run($first);
        $mp3_actions[2]->run(@files);
    };
}

# my $action =

# Detect hibernate/wakeup
# https://www.freedesktop.org/wiki/Software/systemd/logind/

$ld->on('hexdump' => sub {
    eval {
        my ($ld, $prefix,$line) = @_;
        say $prefix . $line;
    }; warn $@ if $@;
});


$ld->on('touch' => sub($ld,$info) {
    # Middle button, not side sliders
    if( defined $info->{button} and 0 < $info->{button} and $info->{button} < 13 ) {
        my @r = $ld->button_rect( $info->{button});
        my ($screen,$x,$y,$w,$h) = @r;
        my $rel = !$info->{released};

        if( $info->{released} ) {
            say $info->{button};
            say $albums[ $info->{button} ]->name;

            play_album($albums[ $info->{button} ]);
        };

    };

    say sprintf "Touch event: id: %d, released: %d, finger: %d, (%d,%d)", $info->{button}, $info->{released}, $info->{finger}, $info->{x}, $info->{y};
});

my $find_albums = Mojo::IOLoop::Subprocess->new();
my $newest_20 = $find_albums->run_p(
    sub {
        map { my $res = eval { $_->as_plain }; warn $@ if $@; $res } @{ $scanner->scan(\@ARGV) };
    },
)->with_roles('+Futurify')->futurify->catch(sub {
    warn Dumper \@_;
    exit;
})->then( sub(@items) {
    my @revived =map {
        Audio::Directory->from_plain($_)
    } @items;
    Future->done(@revived)
})->on_ready(sub {
    say "Albums searched";
});

sub connect_ld() {
    return $ld->connect()->then(sub {
        return $ld->restore_backlight_level()->then(sub {
            return Future->done( $ld );
        });
    })->on_ready(sub {
        say "LD connected";
    });
}
my $connected = connect_ld();

my $msgr;
my $sys_msgr;
my $sleep_inhibitor;

my $dbus_session_ready = $dbus_session->initialize_p()
->with_roles('+Futurify')->futurify->catch(sub {
    warn "No dbus";
    warn Dumper \@_;

})->then(sub($_msgr) {
    say "Subscribing to session events";
    $msgr = $_msgr;
    $msgr->send_call(
        path        => '/org/freedesktop/DBus',
        interface   => 'org.freedesktop.DBus',
        member      => 'AddMatch',
        destination => 'org.freedesktop.DBus',
        signature   => 's',
        body        => [ q<path=/org/mpris/MediaPlayer2> ],
    );
})->on_ready(sub {
    say "Session dbus connected";
});

my $sleep_inhibitor;
sub init_sleep_inhibitor {
    say "Acquiring sleep/shutdown inhibitor";
    return $sys_msgr->send_call(
        interface => 'org.freedesktop.login1.Manager',
        path => '/org/freedesktop/login1',
        member => 'Inhibit',
        destination => 'org.freedesktop.login1',
        signature => 'ssss',
        body => [
            #'sleep:shutdown',
            'sleep',
            'Loupedeck CT handler',
            'Managing Loupedeck CT backlight',
            'block',
            #'delay',
        ],
    )->with_roles('+Futurify')->futurify()
    ->on_ready(sub {
        say "->Inhibit() call returned";
    })
    ->then(sub($msg) {
        $sleep_inhibitor = $msg->get_body->[0];
        say "Successfully acquired inhibitor $sleep_inhibitor";
    })
    ->catch(sub {
        warn "Error when acquiring inhibitor:";
        warn Dumper \@_;
    });
}

my $dbus_ready = $dbus_system->initialize_p()
->with_roles('+Futurify')->futurify->catch(sub {
    warn "No dbus";
    use Data::Dumper;
    warn strftime '%Y-%m-%d %H:%M:%S', localtime;
    warn Dumper \@_;

})->then(sub($msgr) {
    say "Subscribing to system events";
    $sys_msgr = $msgr;
    Future->done();

})->then(sub {
    init_sleep_inhibitor()

})->then(sub {
    # PrepareForShutdown PrepareForSleep
    # True -> sleep
    # False -> wakeup
    $sys_msgr->send_call(
        path        => '/org/freedesktop/DBus',
        interface   => 'org.freedesktop.DBus',
        member      => 'AddMatch',
        destination => 'org.freedesktop.DBus',
        signature   => 's',
        body        => [ q<path=/org/freedesktop/login1> ],
    );

    Future->done();

})->catch(sub {
    use Data::Dumper;

    warn strftime '%Y-%m-%d %H:%M:%S', localtime;
    warn "Error on subscribing: " . Dumper \@_;

})->on_ready(sub {
    say "System dbus connected";
});

# DBus remote control is more or less per-player :-|

sub set_backlight($status) {
    say "Have sleep status '$status'";
    return Future->done()
    ->then( sub {
        my $res;
        if( $status ) {
            # Power off the display
            say "PrepareForSleep - setting backlight level to 0";
            $res = $ld->set_backlight_level(0)
            ->catch(sub {
                warn "Error when sleeping";
                warn Dumper \@_;
            });
            if( $sleep_inhibitor ) {
                say "Done, closing inhibitor '$sleep_inhibitor'";

                close $sleep_inhibitor;
                undef $sleep_inhibitor;
            } else {
                say "Inhibitor was not (yet?!) initialized";
            };

        } else {
            # Power on/restore the display
            # except that we need to figure out where the network connection
            # went, so this is not yet working after hibernation/wakeup
            say "PrepareForSleep - restoring backlight level";
            say "First, sleeping another 30 seconds";
            sleep 30;

            # XXX This might need to be repeated / we might need to
            # reinitialize our websocket connection here
            $ld = init_ld();
            say "Reconnecting LD";
            connect_ld->then(sub {
                $res = $ld->restore_backlight_level
                ->catch(sub {
                    warn "Error when restoring";
                    warn Dumper \@_;
                });
            })->retain;
            say "Re-acquiring (next) sleep inhibitor";
            init_sleep_inhibitor()->retain;
        };
        return $res;
    })->catch( sub {
        warn "Error on backlight:";
        warn Dumper \@_;
    });
}

$SIG{USR1} = sub {
                $ld->set_backlight_level(0)
                ->catch(sub {

                    warn "SIGUSR1: " . Dumper \@_;
                })->retain;
};

$SIG{USR2} = sub {
                $ld->restore_backlight_level()
                ->catch(sub {
                    warn "SIGUSR2: " . Dumper \@_;
                })->retain;
};

$dbus_system->on_signal(sub($msg) {
    use Data::Dumper;
    #say "DBus:";
    #say Dumper [$msg->get_header, $msg->get_body, $msg->get_type];
    #say Dumper $msg;

    #my %type_name = reverse %{ Protocol::DBus::Message::Header::MESSAGE_TYPE() };
    #
    #
    #    my $type = $type_name{ $msg->get_type() };
    #
    #    printf "%s from %s$/", $type, $msg->get_header('SENDER');
    #
    #    printf "\tType: %s.%s$/", map { $msg->get_header($_) } qw( INTERFACE MEMBER );

    say "--- Signal";
    say "INTERFACE: " . $msg->get_header('INTERFACE');
    say "PATH     : " . $msg->get_header('PATH');
    say "MEMBER   : " . $msg->get_header('MEMBER');

# dbus-monitor --system "type='signal',interface='org.freedesktop.NetworkManager'"
# to find if a Loupedeck HD gets added/refound/whatever

    if(     $msg->get_header('INTERFACE') eq 'org.freedesktop.login1.Manager'
        and $msg->get_header('PATH')      eq '/org/freedesktop/login1'
        and $msg->get_header('MEMBER')    eq 'PrepareForSleep'
        ) {
            say "PrepareForSleep - managing Loupedeck HD";

            my $body = $msg->get_body();
            set_backlight($body->[0])->retain;
    } else {
        say "Not for me";
        say Dumper $msg->get_body;
    };

    #if( $msg->
});

my $ready = Future->wait_all( $connected, $newest_20, $dbus_ready, $dbus_session_ready )->then(sub($ld_f,$newest_20_f, $system_dbus, $session_dbus) {
    say "Initializing screen";
    my $button = 1;
    my @newest_20 = $newest_20_f->get;
    my $ld = $ld_f->get;
    say sprintf "Initializing Loupedeck screen (%d items)", 0+@newest_20;

    my @image;

    my $load = Future->done;

    for(@newest_20) {
        $albums[ $button ] = $_;
        if( my $img = $_->album_art ) {
            my $b = $button;
            $load = $load->then( sub {
                $ld->load_image_button( button => $b, file => $img->name, center => 1, update => 1 );
            });
        } else {
            say sprintf "%s has no image file", $_->name;
        };
        $button += 1;
    };
    return $load->then(sub {
        say "Redrawing screen";
        return $ld->redraw_screen('middle');
    });
    Future->done
})->retain;

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
