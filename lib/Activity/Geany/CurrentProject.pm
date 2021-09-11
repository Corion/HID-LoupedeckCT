package Activity::Geany::CurrentProject;
use strict;
use feature 'signatures';
no warnings 'experimental::signatures';

use Path::Class;

use X11::GUITest (qw( GetWindowName GetInputFocus GetParentWindow ));

sub get_named_focus {
    my $win = GetInputFocus();
    my $name;
    do {
        #say $win;
        $name = GetWindowName($win);
        unless ($name) {
            $win = GetParentWindow($win);
        }
    } until $name;
    return $win
}

sub applies($class, $focus_window=get_named_focus()) {
    my $title = GetWindowName($focus_window);
    $title =~ / - Geany$/;
}

sub current_file($class, $focus_window=get_named_focus()) {
    my $title = GetWindowName($focus_window);
    $title =~ /^(.*?) - (.*?) - Geany$/;
    return "$2/$1"
}

sub current_project($class, $focus_window=get_named_focus()) {
    my $f = file($class->current_file( $focus_window ));
    my $dir = $f->dir;

    while( ! -d $dir->subdir('.git') and $dir->parent ne $dir) {
        $dir = $dir->parent;
    }
    return undef if $dir->parent eq $dir;
    return $dir;
}


1;
