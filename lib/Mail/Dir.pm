package Mail::Dir;

use strict;
use warnings;

use Errno;
use IO::Handle;

use Cwd           ();
use Fcntl         ();
use Sys::Hostname ();

use Mail::Dir::Message ();

=head1 NAME

Mail::Dir - Compliant Maildir and Maildir++ delivery mechanism

=head1 SYNOPSIS

    use Mail::Dir;

    my $maildir = Mail::Dir->open("$ENV{'HOME'}/Maildir");

    $maildir->deliver('somefile.msg');

    #
    # Create a new Maildir++ mailbox with sub-mailboxes
    #
    my $maildirPP = Mail::Dir->open("$ENV{'HOME'}/newmaildir",
        'with_extensions' => 1,
        'create'          => 1
    );

    $maildirPP->create_mailbox('INBOX.foo');
    $maildirPP->create_mailbox('INBOX.foo.bar');
    $maildirPP->select_mailbox('INBOX.foo.bar');

    $maildirPP->deliver(\*STDIN);

=head1 DESCRIPTION

C<Mail::Dir> provides a straightforward mechanism for delivering mail messages
to a Maildir or Maildir++ mailbox.

=cut

our $VERSION = '0.01';

my $MAX_BUFFER_LEN      = 4096;
my $MAX_TMP_LAST_ACCESS = 129600;
my $DEFAULT_MAILBOX     = 'INBOX';

sub dirs {
    my ($dir) = @_;

    return (
        'dir' => $dir,
        'tmp' => "$dir/tmp",
        'new' => "$dir/new",
        'cur' => "$dir/cur"
    );
}

=head1 OPENING OR CREATING A MAILBOX

=over

=item C<Mail::Dir-E<gt>open(I<$dir>, I<%opts>)>

Open or create a mailbox, in a manner dependent on the flags specified in
I<%opts>, and returns an object representing the Maildir structure.

Recognized option flags are:

=over

=item * C<create>

When specified, create a Maildir inbox at I<$dir> if one does not already
exist.

=item * C<with_extensions>

When specified, enable management and usage of Maildir++ sub-mailboxes.

=back

=back

=cut

sub open {
    my ( $class, $dir, %opts ) = @_;

    die('No Maildir path specified') unless $dir;

    my %dirs = dirs($dir);

    foreach my $key (qw(dir tmp new cur)) {
        my $dir = $dirs{$key};

        if ( $opts{'create'} ) {
            unless ( -d $dir ) {
                mkdir($dir) or die("Unable to mkdir() $dir: $!");
            }
        }
        else {
            die("Not a directory: $!") unless -d $dir;
        }
    }

    my $hostname = Sys::Hostname::hostname();

    return bless {
        'dir'             => $dir,
        'with_extensions' => $opts{'with_extensions'} ? 1 : 0,
        'hostname'        => $hostname,
        'mailbox'         => $DEFAULT_MAILBOX,
        'deliveries'      => 0
    }, $class;
}

=head1 MANIPULATING MAILBOXES

The following methods require Maildir++ extensions to be enabled.

=over

=item C<$maildir-E<gt>mailbox_dir(I<$mailbox>)>

Return the physical location of the Maildir++ folder corresponding to
I<$mailbox>.

=cut

sub mailbox_dir {
    my ( $self, $mailbox ) = @_;

    die('Maildir++ extensions are required') unless $self->{'with_extensions'};

    $mailbox ||= $self->mailbox;

    my @components = split /\./, $mailbox;
    shift @components;

    my $subdir = join( '.', @components );

    return "$self->{'dir'}/.$subdir";
}

=item C<$maildir-E<gt>select_mailbox(I<$mailbox>)>

Change the current mailbox to which mail is delivered, to I<$mailbox>.

=cut

sub select_mailbox {
    my ( $self, $mailbox ) = @_;

    die('Maildir++ extensions not enabled') unless $self->{'with_extensions'};
    die('Invalid mailbox name')             unless $mailbox =~ /^$DEFAULT_MAILBOX(?:\..*)*$/;
    die('Mailbox does not exist')           unless -d $self->mailbox_dir($mailbox);

    return $self->{'mailbox'} = $mailbox;
}

=item C<$maildir-E<gt>mailbox()>

Returns the name of the currently selected mailbox.

=cut

sub mailbox {
    my ($self) = @_;

    return $self->{'mailbox'};
}

=item C<$maildir-E<gt>mailbox_exists(I<$mailbox>)>

Returns true if I<$mailbox> exists.

=cut

sub mailbox_exists {
    my ( $self, $mailbox ) = @_;

    return -d $self->mailbox_dir($mailbox);
}

sub parent_mailbox {
    my ($mailbox) = @_;

    my @components = split /\./, $mailbox;
    pop @components if @components;

    return join( '.', @components );
}

=item C<$maildir-E<gt>create_mailbox(I<$mailbox>)>

Create the new I<$mailbox> if it does not already exist.  Will throw an error
if the parent mailbox does not already exist.

=back

=cut

sub create_mailbox {
    my ( $self, $mailbox ) = @_;

    die('Maildir++ extensions not enabled') unless $self->{'with_extensions'};
    die('Parent mailbox does not exist') unless $self->mailbox_exists( parent_mailbox($mailbox) );

    my %dirs = dirs( $self->mailbox_dir($mailbox) );

    foreach my $key (qw(dir tmp new cur)) {
        my $dir = $dirs{$key};

        mkdir($dir) or die("Unable to mkdir() $dir: $!");
    }

    return 1;
}

sub name {
    my ( $self, %args ) = @_;

    my $from = $args{'from'} or die('No message file, handle or source subroutine specified');
    my $time = $args{'time'} ? $args{'time'} : time();

    my $name = sprintf( "%d.P%dQ%d.%s", $time, $$, $self->{'deliveries'}, $self->{'hostname'} );

    if ( $self->{'with_extensions'} ) {
        my $size;

        if ( defined $args{'size'} ) {
            $size = $args{'size'};
        }
        elsif ( !ref($from) ) {
            my @st = stat($from) or die("Unable to stat() $from: $!");
            $size = $st[7];
        }

        if ( defined $size ) {
            $name .= sprintf( ",S=%d", $size );
        }
    }

    return $name;
}

sub spool {
    my ( $self, %args ) = @_;

    my $size = 0;

    my $from = $args{'from'} or die('No message file, handle or source subroutine specified to spool from');
    my $to   = $args{'to'}   or die('No message file specified to spool to');

    sysopen( my $fh_to, $to, &Fcntl::O_CREAT | &Fcntl::O_WRONLY ) or die("Unable to open $to for writing: $!");

    if ( ref($from) eq 'CODE' ) {
        $from->($fh_to);

        $fh_to->flush;
        $fh_to->sync;

        $size = tell $fh_to;
    }
    else {
        my $fh_from;

        if ( ref($from) eq 'GLOB' ) {
            $fh_from = $from;
        }
        elsif ( !defined ref($from) ) {
            sysopen( $fh_from, $from, &Fcntl::O_RDONLY ) or die("Unable to open $from for reading: $!");
        }

        while ( my $len = $fh_from->read( my $buf, $MAX_BUFFER_LEN ) ) {
            $size += syswrite( $fh_to, $buf, $len );

            $fh_to->flush;
            $fh_to->sync;
        }

        close $fh_from unless ref($from) eq 'GLOB';
    }

    close $fh_to;

    return $size;
}

=head1 DELIVERING MESSAGES

=over

=item C<$maildir-E<gt>deliver(I<$from>)>

Deliver a piece of mail from the source indicated by I<$from>.  The following
types of values can be specified in I<$from>:

=over

=item * A C<CODE> reference

When passed a C<CODE> reference, the subroutine specified in I<$from> is called,
with a file handle passed that the subroutine may write mail data to.

=item * A file handle

The file handle passed in I<$from> is read until end-of-file condition is
reached, and spooled to a new message in the current mailbox.

=item * A filename

The message at the filename indicated by I<$from> is spooled into the current
mailbox.

=back

=cut

sub deliver {
    my ( $self, $from ) = @_;

    my $oldcwd = Cwd::getcwd() or die("Unable to getcwd(): $!");
    my $dir    = $self->mailbox_dir;
    my $time   = time();

    my $name = $self->name(
        'from' => $from,
        'time' => $time
    );

    chdir($dir) or die("Unable to chdir() to $dir: $!");

    my $file_tmp = "tmp/$name";

    return if -e $file_tmp;

    my $size = $self->spool(
        'from' => $from,
        'to'   => $file_tmp
    );

    my $name_new = $self->name(
        'from' => $file_tmp,
        'time' => $time,
        'size' => $size
    );

    my $file_new = "new/$name_new";

    unless ( rename( $file_tmp => $file_new ) ) {
        die("Unable to deliver incoming message to $file_new: $!");
    }

    my @st = stat($file_new) or die("Unable to stat() $file_new: $!");

    chdir($oldcwd) or die("Unable to chdir() to $oldcwd: $!");

    $self->{'deliveries'}++;

    return Mail::Dir::Message->from_file(
        'maildir' => $self,
        'mailbox' => $self->{'mailbox'},
        'dir'     => 'new',
        'file'    => "$dir/$file_new",
        'name'    => $name_new,
        'st'      => \@st
    );
}

=back

=head1 RETRIEVING MESSAGES

=over

=item C<$maildir-E<gt>messages(I<%opts>)>

Return a list of L<Mail::Dir::Message> references containing mail messages as
selected by the criteria specified in I<%opts>.  Options include:

=over

=item * C<tmp>, C<new>, C<cur>

When any of these are set to 1, messages in those queues are processed.

=item * C<filter>

A subroutine can be passed via C<CODE> reference which filters for messages
that are desired.  Each L<Mail::Dir::Message> object is passed to the
subroutine as its sole argument, and is kept if the subroutine returns 1.

=back

=back

=cut

sub messages {
    my ( $self, %opts ) = @_;
    my $dir = $self->mailbox_dir;

    my @ret;

    foreach my $key (qw(tmp new cur)) {
        next unless $opts{$key};

        my $path = "$dir/$key";

        opendir( my $dh, $path ) or die("Unable to opendir() $path: $!");

        while ( my $item = readdir($dh) ) {
            next if $item =~ /^\./;

            my $file = "$path/$item";
            my @st = stat($file) or die("Unable to stat() $file: $!");

            my $message = Mail::Dir::Message->from_file(
                'maildir' => $self,
                'mailbox' => $self->{'mailbox'},
                'dir'     => $key,
                'file'    => $file,
                'name'    => $item,
                'st'      => \@st
            );

            if ( defined $opts{'filter'} ) {
                next unless $opts{'filter'}->($message);
            }

            push @ret, $message;
        }

        closedir $dh;
    }

    return \@ret;
}

=head1 PURGING EXPIRED MESSAGES

=over

=item C<$maildir-E<gt>purge()>

Purge all messages in the C<tmp> queue that have not been accessed for the past
36 hours.

=back

=cut

sub purge {
    my ($self) = @_;
    my $time = time();

    my $messages = $self->messages(
        'tmp'    => 1,
        'filter' => sub {
            my ($message) = @_;

            return ( $time - $message->{'atime'} > $MAX_TMP_LAST_ACCESS ) ? 1 : 0;
        }
    );

    foreach my $message ( @{$messages} ) {
        unlink( $message->{'file'} ) or die("Unable to unlink() $message->{'file'}: $!");
    }

    return $messages;
}

1;

__END__

=head1 SEE ALSO

=over

=item C<L<Mail::Dir::Message>> - Manipulate messages in a Maildir queue

=back

=head1 AUTHOR

Xan Tronix <xan@cpan.org>

=head1 COPYRIGHT

Copyright (c) 2014, cPanel, Inc.  Distributed under the terms of the MIT
license.
