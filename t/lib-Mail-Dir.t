#! perl

use strict;
use warnings;

use File::Temp ();

use Mail::Dir ();

use Test::More ('no_plan');
use Test::Exception;
use Errno;

my $tmpdir = File::Temp::tempdir('CLEANUP' => 1);

{
    note('Testing plain Maildir support');

    my $maildir_path = "$tmpdir/Maildir";
    my $maildir;

    throws_ok {
        Mail::Dir->open;
    } qr/^No Maildir path specified/, 'Mail::Dir->open() die()s if no directory was provided';

    throws_ok {
        Mail::Dir->open('/dev/null/impossible',
            'create' => 1
        );
    } qr/^Unable to mkdir\(\)/, 'Mail::Dir->open() die()s with "create" if it cannot create a directory';

    throws_ok {
        Mail::Dir->open('/dev/null');
    } qr/^Not a directory/, 'Mail::Dir->open() die()s if passed a non-directory path';

    eval {
        Mail::Dir->open($maildir_path);
    };

    ok( defined $@ && $!{'ENOENT'}, 'Mail::Dir->open() die()s if asked to open nonexistent Maildir' );
    
    lives_ok {
        $maildir = Mail::Dir->open($maildir_path,
            'create' => 1
        );
    } 'Mail::Dir->open() is able to create a nonexistent Maildir';

    lives_ok {
        Mail::Dir->open($maildir_path,
            'create' => 1
        );
    } 'Mail::Dir->open() will not complain if "create" passed on existing Maildir';

    lives_ok {
        Mail::Dir->open($maildir_path);
    } 'Mail::Dir->open() will successfully open an existing Maildir directory';

    throws_ok {
        $maildir->mailbox_dir
    } qr/^\QMaildir++ extensions are required\E/, '$maildir->mailbox_dir() die()s when running on a mailbox without Maildir++ extensions';
}

{
    note('Testing with Maildir++ extensions');

    my $maildir_path = "$tmpdir/MaildirPlusPlus";
    my $maildir;

    lives_ok {
        $maildir = Mail::Dir->open($maildir_path,
            'create'          => 1,
            'with_extensions' => 1
        );
    } 'Mail::Dir->open() will create a new Maildir++ queue without complaint';

    lives_ok {
        Mail::Dir->open($maildir_path,
            'with_extensions' => 1
        );
    } 'Mail::Dir->open() will open an existing Maildir++ queue without complaint';

    ok( -d $maildir->mailbox_dir, '$maildir->mailbox_dir() returns the current Maildir++ physical directory' );
    ok( -d $maildir->mailbox_dir('INBOX'), '$maildir->mailbox_dir() returns the physical location of INOBX' );

    lives_ok {
        $maildir->select_mailbox('INBOX');
    } '$maildir->select_mailbox() will change the mailbox to INBOX without complaint';

    throws_ok {
        $maildir->select_mailbox('INBOX.nonexistent');
    } qr/^Mailbox does not exist/, '$maildir->select_mailbox() die()s when passed a nonexistent mailbox';

    lives_ok {
        $maildir->create_mailbox('INBOX.new');
    } '$maildir->create_mailbox() successfully creates a new mailbox';

    lives_ok {
        $maildir->select_mailbox('INBOX.new');
    } '$maildir->select_mailbox() will change the mailbox to INBOX.new without complaint';

    my $old = $maildir->mailbox_dir('INBOX');
    my $new = $maildir->mailbox_dir;

    isnt( $old => $new, '$maildir->mailbox_dir() returns a new result after changing mailbox to INBOX.new' );
    ok( -d $new, '$mailbox->mailbox_dir() returns a valid directory after changing mailbox to INBOX.new' );
}
