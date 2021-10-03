#!perl
use 5.020;
use feature 'signatures';
no warnings 'experimental::signatures';
use Future::Utils 'repeat';
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
use charnames ':full';

our $VERSION = '0.01';

use X11::GUITest qw(GetInputFocus GetWindowName GetParentWindow);

use POSIX 'strftime';
use Data::Dumper;

# These should become plugins, and get a proper namespace, etc. ...
use Activity::Geany::CurrentProject;
use Assistant::Timers;

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

my @albums;
my %actions;


# We want/need a watchdog (much like the websocket watchdog) to know if the
# device has gone away (likely unplugged), and maybe also to detect if the
# device comes back (replugged)
sub init_ld($uri) {
    my $ld = HID::LoupedeckCT->new(
        maybe uri => $uri,
              verbose => 1,
    );

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
                #say $info->{button};
                say $albums[ $info->{button} ]->name;

                play_album($albums[ $info->{button} ]);
            };

        } else {
            say sprintf "Touch event: id: %d, released: %d, finger: %d, (%d,%d)", $info->{button}, $info->{released}, $info->{finger}, $info->{x}, $info->{y};
        };
    });

    $ld->on('wheel_touch' => sub($ld,$info) {
        return unless $info->{released};
        # Maybe allow more areas for the wheel?!
        if( my $cb = $actions{ 'wheel_touch' }) {
            $cb->( $info );
        };
    });

    $ld->on('key' => sub( $ld, $info ) {
        return unless $info->{released};
        if( my $cb = $actions{ $info->{id}}) {
            $cb->( $info );
        };
    });

    return $ld
}
my $ld = init_ld($uri);

my $dbus_system = Protocol::DBus::Client::Mojo::system();
my $dbus_session = Protocol::DBus::Client::Mojo::login_session();

#if( ! $ld->uri ) {
#    die "Couldn't autodetect Loupedeck CT, sorry";
#}
say "Connecting to " . $ld->uri;

my (@mp3_actions) = mime_applications('audio/mpeg');
my (@pl_actions) = mime_applications('audio/x-mpegurl');

#for (@mp3_actions) {
#    say join " - ", $_->Name, $_->Text;
#}

sub play_album( $album ) {
    if( my $pl = $album->playlist ) {
        say $pl_actions[1]->Name;
        $pl_actions[1]->run($pl->name);
    } else {
        # The other players behave even weirder than SMPlayer (!)
        # We assume that the second mention of the default player is the "enqueue action" ...
        my ($playfile, $queue_files) = grep { $_->Name =~ /\bSMPlayer\b/ } @mp3_actions;

        my @files = map { $_->name } sort {
                      $a->{album} cmp $b->{album} # so we sort CD1 before CD2 ...
                   || $a->{track} <=> $b->{track}
                   || $a->{url} cmp $b->{url}
                 } $album->music_files;
        my $first = shift @files;
        $playfile->run($first);
        #say $queue_files->Name;
        # We need to delay the appending of files, otherwise SMPlayer gets confused ...
        Mojo::IOLoop->timer(1 => sub {
            $queue_files->run(@files);
        });
    };
}

sub rescan_files( @directories ) {
    my $find_albums = Mojo::IOLoop::Subprocess->new();
    my $newest_20 = $find_albums->run_p(
        sub {
            map { my $res = eval { $_->as_plain }; warn $@ if $@; $res } @{ $scanner->scan(\@directories) };
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
        my @count = $_[0]->result;
        my $count = 0+@count;
        say "Albums searched ($count found)";
    });
    return $newest_20;
}

my $newest_20 = rescan_files( @ARGV );

sub connect_ld() {
    my $connected = repeat {
        $ld->connect
        ->followed_by( sub {! $ld->connected })
    } while => sub { shift->result };
    return $connected->then(sub {
        return $ld->restore_backlight_level()->then(sub {
            return Future->done( $ld );
        });
    })->on_ready(sub {
        say "*** LD connected";
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
            #sleep 5;

            say "Found LoupeDeck devices";
            for my $uri (HID::LoupedeckCT->list_loupedeck_devices()) {
                say $uri;
            };
            say "Current device we think we use";
            say $ld->uri;

            # Maybe we should loop until we (re)find the LD?!

            # XXX This might need to be repeated until we (re)find a device
            #     or until we give up
            $ld = init_ld($uri);
            say "Reconnecting LD";
            connect_ld->then(sub {
                $res = $ld->restore_backlight_level
                ->catch(sub {
                    warn "Error when restoring";
                    warn Dumper \@_;
                });
            })->then(sub {
                # We should maybe have a list of things we want to reinitialize
                # like also everything that depends on other state?!
                reload_album_art( @albums );

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

sub reload_album_art( @albums ) {
    my $load = Future->done;

    for my $button (1..$#albums) {
        my $album = $albums[ $button ];
        if( !$album) {
            say "Skipping album $button (no info)";
        };
        if( my $img = $album->album_art ) {
            my $btn = $button;
            #say sprintf "Queueing %s", $img->name;
            #push @images,
            $load = $load->then( sub {
                #say sprintf "Loading %s on %s", $img->name, $btn;
                $ld->load_image_button( button => $btn, file => $img->name, center => 1, update => 0 )
                #$ld->load_image_button( button => $btn, string => "\N{DROMEDARY CAMEL}", center => 1 )
                #->on_ready(sub {
                #    say sprintf "Image %s done", $img->name;
                #})
                ->catch(sub {
                    use Data::Dumper;
                    warn Dumper \@_;
                });
            });
        } else {
            say sprintf "%s has no image file", $album->name;
        };
    };
    #my $load = Future->wait_all(@images);
    return $load->then(sub {
        say "Redrawing screen";
        return $ld->redraw_screen('middle');
    });
}

my $rescan;
my $ready = Future->wait_all( $connected, $newest_20, $dbus_ready, $dbus_session_ready )->then(sub($ld_f,$newest_20_f, $system_dbus, $session_dbus) {
    #say "Initializing screen";
    # Button 0 stays empty
    @albums = (undef, $newest_20_f->get);
    my $ld = $ld_f->get;
    say sprintf "Initializing Loupedeck screen (%d items)", $#albums;

    #my @image;

    #Future->done

    # Rescan if a process is running
    $rescan = Mojo::IOLoop->recurring( 1 => sub {
        rescan_processes()
    });

    return reload_album_art( @albums );
})->catch(sub {
    use Data::Dumper;
    say Dumper \@_;
})->retain;

# Rescan all music files every 30 minutes
my $refresh = Mojo::IOLoop->recurring( 60*30 => sub {
    rescan_files(@ARGV)->then(sub( @new_albums) {
        say "Refreshing album list from @ARGV";
        @albums = (undef, @new_albums);
        say sprintf "Initializing Loupedeck screen (%d items)", $#albums;
        return reload_album_art( @albums );
    })->retain;
});

# This needs a patched version of X11::GUITest that doesn't crash the process
# on windows having gone away while looping through window handles ...
sub get_named_focus_window {
    my $win = GetInputFocus();
    my $name;
    # We return undef if the window has gone away
    do {
        $name = GetWindowName($win);
        unless ($name) {
            $win = GetParentWindow($win);
        }
    } until $name or ($win == 0);
    return $win
}

my @check = (
        { name => 'Webcam',
          cmdline => qr/\bgphoto2\b.*?\b\0--capture-movie\0/ms,
          launch_action => sub( $cfg, $pid ) {
              $ld->set_button_color($cfg->{button},255,0,0)->retain;
              $actions{ $cfg->{button}} = sub {
                  $pid =~ /(\d+)$/ or die "No pid to kill?!";
                  kill KILL => $1;
              },
          },
          none_action    => sub( $cfg, $pid ) {
              $ld->set_button_color($cfg->{button},0,0,0)->retain;
              $actions{ $cfg->{button}} = sub {
                  system("gphoto2 --stdout --capture-movie | ffmpeg -hide_banner -i - -vcodec rawvideo -tune zerolatency -pix_fmt yuv420p -threads 0 -f v4l2 /dev/video1 &");
              },
          },
          button => 15,
        },
        { name => 'Audio controls',
          cmdline => qr/\bpavucontrol-qt\0/ms,
          launch_action => sub( $cfg, $pid ) {
              $ld->set_button_color($cfg->{button},0,127,0)->retain;
              $actions{ $cfg->{button}} = sub {
                  system('xdotool search --class "pavucontrol-qt" windowactivate');
              },
          },
          none_action    => sub( $cfg, $pid ) {
              $ld->set_button_color($cfg->{button},0,0,0)->retain;
              $actions{ $cfg->{button}} = sub {
                  system('pavucontrol-qt &');
              },
          },
          button => 14,
        },

        # The same could hold for git, and maybe also even a shell prompt
        # Maybe also I want a hotkey for "git gui here" ?!
        { name => 'Geany test suite status',
          # We want to look if Geany is running, extract the project directory
          # from the current file, then check if there is a `prove` process
          # (or maybe an inotify watcher?) running, and if not, run it, and
          # extract the status as yellow -> red/green
          # Split that up in two programs:
          #     provewatcher -> run the test suite whenever a project file changes
          #     prove-status -> parse .prove, and update the status accordingly
          #cmdline => qr/\bgeany\0/ms,
          focus => qr/\b - Geany$/,
          focused_action => sub( $cfg, $pid ) {
              # Do we want to do anything here?!
              # Set the button according to the status found in .prove
              #warn "Checking for Geany project";
              my $project = Activity::Geany::CurrentProject->current_project;
              if( $project ) {
                  #warn "Current project: $project";
                  # Check if a .prove exists, maybe?
                  my $status = system('/home/corion/Projekte/HID-LoupedeckCT/scripts/prove-status.pl', '-f', "$project/.prove");
                  #warn "Test status: $status";
                  if( $status ) {
                      $ld->set_button_color($cfg->{button},255,0,0)->retain;
                  } else {
                      $ld->set_button_color($cfg->{button},0,255,0)->retain;
                  };
              };
          },
          blur_action => sub( $cfg, $pid ) {
              # Launch autoprove in the project directory
              $ld->set_button_color($cfg->{button},0,0,0)->retain;
          },
          button => 18,
        },

        # The same could hold for git, and maybe also even a shell prompt
        # Maybe also I want a hotkey for "git gui here" ?!
        { name => 'Start/stop 6 minute timer',
          button => undef, # need to find out how we want to handle the wheel
          on_tick => sub( $cfg, $time ) {
              state $timer = Assistant::Timers->new( duration => 360 );

              if( $timer->expired($time) ) {
                  $ld->vibrate(1);
              };
              $actions{ 'wheel_touch' } //= sub( $info ) {
                  my $rel = $info->{released};
                  if( $rel and $timer->expired() ) {
                      #say "Stopping alarm";
                      $timer->stop;
                  } elsif( $rel and $timer->started() ) {
                      if( $timer->paused ) {
                          $timer->unpause
                      } else {
                        say "Pausing timer";
                        $timer->pause;
                      };
                  } elsif( $rel and $timer->stopped($time) ) {
                      #say "Starting timer";
                      $timer->start
                  };
              };
              # (re)draw the timer on the wheel
              # ...
              if( $timer->started() ) {
                  my $rem = $timer->remaining($time);
                  my $str = sprintf '%02d:%02d:%02d', int( $rem / 3600 ), int($rem/60) % 60, $rem%60;
                  my $img = $ld->_text_image(240,240,$str, bgcolor => [0,0,0]);
                  $ld->load_image( screen => 'wheel', image => $img, update => 1 )->retain;
              } elsif( $timer->paused() ) {
                  # blink it every second
              } elsif( $timer->expired() ) {
                  # what do we display here?!
              } else {
                  # clear the screen
                  $ld->set_screen_color( 'wheel', 0,0,0)->then(sub {
                      $ld->redraw_screen('wheel');
                  })->retain;
              }
          },
          # Maybe we want on_show/on_hide to configure the buttons and allow
          # changing of the config?!

        },
);

# Actually, this not only scans processes but also windows. This will need
# splitting and moving to a different module :)
# It now also handles setting up a timer button, which has nothing to do
# with all of these ...
# This is rather the main loop...
sub rescan_processes {
    state %last_running;
    state %last_focused;

    my %running;
    my %focused;

    # We should also store the time since this window has the focus to also
    # enable stuff like "When looking for more than a minute at this window"
    my $focus_window = get_named_focus_window();
    my $window_title = GetWindowName($focus_window);
    for my $test (@check) {
        my $name = $test->{name};
        my $title_re = $test->{focus};
        if( $title_re and $window_title =~ /$title_re/ ) {
            $focused{ $name } = { test => $test, window => $focus_window };
        } else {
            # So we know that this has been checked
            $focused{ $name } ||= undef;
        }
    };

    # This is very specific to Linux
    for my $pid (glob '/proc/*') {
        open my $fh, '<', "$pid/cmdline"
            or next;
        local $/;
        my $cmdline = <$fh>;
        close $fh;

        for my $test (@check) {
            my $name = $test->{name};
            my $cmdline_re = $test->{cmdline};
            if( $cmdline_re and $cmdline =~ /$cmdline_re/ ) {
                $running{ $name } = { test => $test, pid => $pid };
            } else {
                # So we know that this has been checked
                $running{ $name } ||= undef;
            }
        };
    }

    # Only trigger when the sense changes between running/not running
    for my $test (@check) {
        my $name = $test->{name};

        # A test might get triggered for "running" and "focused" currently...

        my $focus_action;
        if( ! exists $last_focused{ $name } and not $focused{ $name }->{window}) {
            # First time we see this test, and it's not focused, nothing to do
        } elsif( ! exists $last_focused{ $name } and $focused{ $name }->{window}) {
            # We switched to this window
            $focus_action = $test->{focus_action};

        } elsif( exists $last_focused{ $name } and ! $focused{ $name }->{window}) {
            # We switched from this window
            $focus_action = $test->{blur_action};

        } elsif( exists $last_focused{ $name } and $focused{ $name }->{window}) {
            # We stayed with this window
            $focus_action = $test->{focused_action};
        }
        if( $focus_action ) {
            $focus_action->( $test, $focused{ $name }->{window})
        };

        my $run_action;
        if( ! exists $last_running{ $name } and not $running{ $name }->{pid}) {
            # This is the first time we check at all, so initialize to "not running"
            $run_action = $test->{none_action};
            warn "Initializing '$name' at start (not running)";
        } elsif( ! exists $last_running{ $name } and $running{ $name }->{pid}) {
            # This is the first time we check at all and the process is running already
            warn "Initializing '$name' at start (already running)";
            $run_action = $test->{running_action} || $test->{launch_action};
        } elsif( $running{ $name } and ! $last_running{ $name }->{pid}) {
            warn "'$name' was newly launched";
            $run_action = $test->{launch_action};
        } elsif( !$running{ $name } and $last_running{ $name }->{pid}) {
            warn "'$name' has gone away";
            $run_action = $test->{stop_action} || $test->{none_action};
        } elsif( $running{ $name } and $last_running{ $name }->{pid} and my $c = $test->{running_action}) {
            #warn "'$name' is running and we want notifications";
            $run_action = $test->{running_action};

        } else {
            # Nothing to be done
        }
        if( $run_action ) {
            $run_action->( $test, $running{ $name }->{pid})
        };

        if( my $c = $test->{on_tick}) {
            $c->( $test, time());
        };
    }

    %last_running = %running;
    %last_focused = %focused;

    if( $ld->{needs_refresh}) {
        reload_album_art( @albums )->retain;
        undef $ld->{needs_refresh};
    };
}

# We want to stop the program gracefully even if we get CTRL+C
$SIG{INT} = sub {
    if( $ld ) {
        $ld->disconnect;
        Mojo::IOLoop->stop_gracefully;
    }
};
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;


# Multiple timers on buttons?!
# Prima for display of info on main screen(s)?!
# Ascii pop-up (Prima)
# Calendar pop-up (from WebDAV)
# HTML pop-up (via Chrome?!)
