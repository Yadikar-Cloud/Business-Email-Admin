#!/usr/bin/perl

use DBI;
use MIME::Base64;
# use Data::Dumper;
use File::Temp qw/ mkstemp /;
use Sys::Syslog;
# require liblockfile-simple-perl
use LockFile::Simple qw(lock trylock unlock);

######################################################################
########## Change the following variables to fit your needs ##########

# database settings

# database backend - uncomment one of these
our $db_type = 'Pg';
#my $db_type = 'mysql';

# host name
our $db_host="127.0.0.1";
# database name
our $db_name="postfix";
# database username
our $db_username="mail";
# database password
our $db_password="CHANGE_ME!";

# Where to create a lockfile; please ensure path exists.
our $run_dir="/var/lock/fetchmail";

# in case you want to use dovecot deliver to put the mail directly into the users mailbox,
# set "mda" in the fetchmail table to the keyword "dovecot".

# Where the delivery binary is located
$dovecot_deliver = "/usr/lib/dovecot/deliver";

# instead of changing this script, you can put your settings to /etc/mail/postfixadmin/fetchmail.conf
# just use perl syntax there to fill the variables listed above (without the "our" keyword). Example:
# $db_username = 'mail';
if (-f "/etc/mail/postfixadmin/fetchmail.conf") {
	require "/etc/mail/postfixadmin/fetchmail.conf";
}


#################### Don't change anything below! ####################
######################################################################

openlog("fetchmail-all", "pid", "mail");

sub log_and_die {
  my($message) = @_;
  syslog("err", $message);
  die $message;
}

sub escape_password {
    $output = "";
    for $i (0..length($_[0])-1){
        $char = substr($_[0], $i, 1);
        if ($char eq "\\" or $char eq "\"")
        {
            $output = $output . "\\";
        }
        $output = $output . $char;
    }
    return $output;
}
# read options and arguments

$configfile = "/etc/fetchmail-all/config";

@ARGS1 = @ARGV;

while ($_ = shift @ARGS1) {
    if (/^-/) {
        if (/^--config$/) {
            $configfile = shift @ARGS1
        }
    }
}

# use specified config file
if (-e $configfile) {
    do $configfile;
}

if($db_type eq "Pg" || $db_type eq "mysql") {
	$dsn = "DBI:$db_type:database=$db_name;host=$db_host";
} else {
	log_and_die "unsupported db_type $db_type";
}

if(!-d $run_dir) {
    log_and_die("Please create: $run_dir");
}

$lock_file=$run_dir . "/fetchmail-all.lock";

$lockmgr = LockFile::Simple->make(-autoclean => 1, -max => 1);
$lockmgr->lock($lock_file) || log_and_die "can't lock ${lock_file}";

# database connect
$dbh = DBI->connect($dsn, $db_username, $db_password) || log_and_die "cannot connect the database";

if($db_type eq "Pg") {
	$sql_cond = "active = 't' AND date_part('epoch',now())-date_part('epoch',date)";
} elsif($db_type eq "mysql") {
	$sql_cond = "active = 1 AND unix_timestamp(now())-unix_timestamp(date)";
}

$sql = "
	SELECT id,mailbox,src_server,src_auth,src_user,src_password,src_folder,fetchall,keep,protocol,mda,extra_options,usessl, sslcertck, sslcertpath, sslfingerprint, src_port
	FROM fetchmail
	WHERE $sql_cond  > poll_time*60
	";

my (%config);
map{
	my ($id,$mailbox,$src_server,$src_auth,$src_user,$src_password,$src_folder,$fetchall,$keep,$protocol,$mda,$extra_options,$usessl,$sslcertck,$sslcertpath,$sslfingerprint,$src_port)=@$_;

	syslog("info","fetch ${src_user}@${src_server} for ${mailbox}");

	$cmd="user '${src_user}' there with password '".escape_password(decode_base64($src_password))."'";
	$cmd.=" folder '${src_folder}'" if ($src_folder);

	if ($mda) {
		if ($mda eq "dovecot") {
			$cmd.=" mda \"${dovecot_deliver} -d ${mailbox}\" ";
		} else {
			$cmd.=" mda ".$mda 
		}
	}

#	$cmd.=" mda \"/usr/local/libexec/dovecot/deliver -m ${mailbox}\"";
	$cmd.=" is '${mailbox}' here";

	$cmd.=" keep" if ($keep);
	$cmd.=" fetchall" if ($fetchall);
	$cmd.=" ssl" if ($usessl);
	$cmd.=" sslcertck" if($sslcertck);
	$cmd.=" sslcertpath $sslcertpath" if ($sslcertck && $sslcertpath);
	$cmd.=" sslfingerprint \"$sslfingerprint\"" if ($sslfingerprint);
	$cmd.=" ".$extra_options if ($extra_options);

	$text=<<TXT;
set postmaster "postmaster"
set nobouncemail
set no spambounce
set properties ""
set syslog

TXT
    $text.="poll ${src_server} with proto ${protocol}";
    $text.=" service ${src_port}" if ($src_port);
    $text.="\n	$cmd";


  ($file_handler, $filename) = mkstemp( "/tmp/fetchmail-all-XXXXX" ) or log_and_die "cannot open/create fetchmail temp file";
  print $file_handler $text;
  close $file_handler;

  $ret=`/usr/bin/fetchmail -f $filename --pidfile $run_dir/fetchmail.pid`;

  unlink $filename;

  $sql="UPDATE fetchmail SET returned_text=".$dbh->quote($ret).", date=now() WHERE id=".$id;
  $dbh->do($sql);
}@{$dbh->selectall_arrayref($sql)};

$lockmgr->unlock($lock_file);
closelog();
