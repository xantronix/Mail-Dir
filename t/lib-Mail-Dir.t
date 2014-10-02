#! perl

use strict;
use warnings;

use File::Temp ();

use Mail::Dir ();

use Test::More ('no_plan');
use Test::Exception;
use Errno;

sub create_message_text {
    return <<EOF;
From: Foo
To: Bar
Subject: Cats

Meow!
EOF
}

sub create_message_file {
    my ($file) = @_;

    open(my $fh, '>', $file) or die("Unable to open $file for writing: $!");
    print {$fh} create_message_text();
    close $fh;

    return $file;
}

sub create_message_sub {
    return sub {
        my ($fh) = @_;
        print {$fh} create_message_text();
        return;
    };
}

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
        $maildir->select_mailbox('INBOX');
    } qr/^\QMaildir++ extensions not enabled\E/, '$maildir->select_mailbox() die()s when running on a mailbox without Maildir++ extensions';

    throws_ok {
        $maildir->create_mailbox('INBOX.new');
    } qr/^\QMaildir++ extensions not enabled\E/, '$maildir->create_mailbox() die()s when running on a mailbox without Maildir++ extensions';

    throws_ok {
        $maildir->deliver;
    } qr/^No message source provided/, '$maildir->deliver() die()s when no message source provided';

    note('Testing Maildir message delivery');

    my $msgfile = "$tmpdir/msg.txt";

    create_message_file($msgfile);

    lives_ok {
        $maildir->deliver($msgfile);
    } '$maildir->deliver() succeeds when delivering message from file';

    lives_ok {
        $maildir->deliver(create_message_sub());
    } '$maildir->deliver() succeeds when delivering message from CODE ref';

    open(my $fh, '<', $msgfile);

    lives_ok {
        $maildir->deliver($fh);
    } '$maildir->deliver() succeeds when delivering message from file handle';

    close $fh;

    note('Testing Maildir message retrieval');

    is( scalar @{$maildir->messages()} => 0, '$maildir->messages() returns nothing when passed no options' );

    {
        my $messages = $maildir->messages(
            'tmp' => 1,
            'new' => 1,
            'cur' => 1
        );

        is( scalar @{$messages} => 3, '$maildir->messages() returns 3 messages for tmp, new and cur without a filter' );
    }

    {
        my $messages = $maildir->messages(
            'tmp' => 1,
            'new' => 1,
            'cur' => 1
        );

        foreach my $message (@{$messages}) {
            my $fh;

            lives_ok {
                $fh = $message->open;
            } '$message->open() able to open message as file';

            close $fh if $fh;
        }
    }

    {
        my $messages = $maildir->messages(
            'tmp' => 1,
            'new' => 1,
            'cur' => 1,
            'filter' => sub {
                my ($message) = @_;
                my $match = 0;

                my $fh = $message->open;

                while (my $line = readline($fh)) {
                    chomp $line;

                    if ($line =~ /^From: Foo/) {
                        $match = 1;
                        last;
                    }
                }

                return $match;
            }
        );

        is( scalar @{$messages} => 3, '$maildir->messages() able to retrieve all messages successfully with filter');
    }
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

    lives_ok {
        $maildir->select_mailbox('INBOX');
    } '$maildir->select_mailbox() will change the mailbox to INBOX without complaint';

    throws_ok {
        $maildir->select_mailbox('INBOX.nonexistent');
    } qr/^Mailbox does not exist/, '$maildir->select_mailbox() die()s when passed a nonexistent mailbox';

    lives_ok {
        $maildir->create_mailbox('INBOX.new');
    } '$maildir->create_mailbox() successfully creates a new mailbox';

    throws_ok {
        $maildir->create_mailbox('INBOX.impossible.mailbox');
    } qr/^Parent mailbox does not exist/, '$maildir->create_inbox() die()s when passed a mailbox path with nonexistent parent';

    lives_ok {
        $maildir->select_mailbox('INBOX.new');
    } '$maildir->select_mailbox() will change the mailbox to INBOX.new without complaint';

    throws_ok {
        $maildir->select_mailbox('//invalid');
    } qr/^Invalid mailbox name/, '$maildir->select_mailbox() will die() if provided an invalid mailbox name';

    note('Testing Maildir++ message delivery');

    my $msgfile = "$tmpdir/msg.txt";

    create_message_file($msgfile);
}
