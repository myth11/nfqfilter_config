#!/usr/bin/perl

# создаем нужные файлы из БД rkn
# Внимание!!! IP адреса в базе должны храниться в виде байт, а не целого числа.

use strict;
use warnings;
use utf8;
use Config::Simple;
use DBI;
use File::Basename;
use URI;
use POSIX;
use Digest::MD5 qw (md5);
use Log::Log4perl;
use Net::IP qw(:PROC);
use Encode;
use Net::CIDR::Lite;
use IPC::Open2;


binmode(STDOUT,':utf8');
binmode(STDERR,':utf8');

my $dir = File::Basename::dirname($0);

my $Config = {};
Config::Simple->import_from($dir.'/rkn.conf', $Config) or die "Can't open ".$dir."/rkn.conf for reading!\n";
Log::Log4perl::init( $dir."/rkn_log.conf" );

my $logger=Log::Log4perl->get_logger();


my $db_host = $Config->{'DB.host'} || die "DB.host not defined.";
my $db_user = $Config->{'DB.user'} || die "DB.user not defined.";
my $db_pass = $Config->{'DB.password'} || die "DB.password not defined.";
my $db_name = $Config->{'DB.name'} || die "DB.name not defined.";

# пути к генерируемым файлам:
my $bgpd_file = $Config->{'BGP.quagga_config'} || "";
my $domains_file = $Config->{'APP.domains'} || "";
my $urls_file = $Config->{'APP.urls'} || "";
my $ssls_file = $Config->{'APP.ssls'} || "";
my $hosts_file = $Config->{'APP.hosts'} || "";
my $protos_file = $Config->{'APP.protocols'} || "";
my $ssls_ips_file = $Config->{'APP.ssls_ips'} || "";
my $domains_ssl = $Config->{'APP.domains_ssl'} || "true";
$domains_ssl = lc($domains_ssl);
my $only_original_ssl_ip = $Config->{'APP.only_original_ssl_ip'} || "false";
$only_original_ssl_ip = lc($only_original_ssl_ip);

my $bgp_as = $Config->{'BGP.our_as'} || "";
my $bgp_router_id = $Config->{'BGP.router_id'} || "";
my $bgp_neighbor = $Config->{'BGP.neighbor'} || "";
my $bgp_remote_as = $Config->{'BGP.remote_as'} || "";
my $bgp6_neighbor = $Config->{'BGP.neighbor6'} || "";
my $vtysh = $Config->{'BGP.vtysh'} || "/bin/vtysh";

my $update_soft_quagga=1;

my $dbh = DBI->connect("DBI:mysql:database=".$db_name.";host=".$db_host,$db_user,$db_pass,{mysql_enable_utf8 => 1}) or die DBI->errstr;
$dbh->do("set names utf8");


my $domains=0;
my $only_ip=0;
my $urls=0;
my $https=0;
my $total_entry=0;
my %ip_s;
my %ip6_s;
my %ip_s_null;
my %ip6_s_null;
my %already_out;

my $ip_cidr=new Net::CIDR::Lite;
my $ip_cidr_null=new Net::CIDR::Lite;
my $ip6_cidr=new Net::CIDR::Lite;
my $ip6_cidr_null=new Net::CIDR::Lite;

my @ip_list;
my @ip6_list;
my @ip_list_null;
my @ip6_list_null;

my $domains_file_hash_old=get_md5_sum($domains_file);
my $urls_file_hash_old=get_md5_sum($urls_file);
my $ssl_host_file_hash_old=get_md5_sum($ssls_file);
my $net_file_hash_old=get_md5_sum($bgpd_file);

open (my $DOMAINS_FILE, ">",$domains_file) or die "Could not open DOMAINS '$domains_file' file: $!";
open (my $URLS_FILE, ">",$urls_file) or die "Could not open URLS '$urls_file' file: $!";
open (my $SSL_HOST_FILE, ">",$ssls_file) or die "Could not open SSL hosts '$ssls_file' file: $!";
open (my $SSL_IPS_FILE, ">", $ssls_ips_file) or die "Could not open SSL ips '$ssls_ips_file' file: $!";

my $cmd = "$vtysh -c 'show run'";
my $show_run=`$cmd`;
if ( $? == -1 )
{
	$logger->error("Error while executed cmd $cmd: $!, skip soft Quagga reconfiguration");
	$update_soft_quagga=0;
}

my $NET_FILE;
if(!$update_soft_quagga)
{
	open ($NET_FILE, ">",$bgpd_file) or die "Could not open file '$bgpd_file' $!";
	print $NET_FILE "! Generated by super-puper script\n!\n!\nrouter bgp $bgp_as\n bgp router-id $bgp_router_id\n neighbor $bgp_neighbor remote-as $bgp_remote_as\n neighbor $bgp6_neighbor remote-as $bgp_remote_as\n no neighbor $bgp6_neighbor activate\n";
}

open (my $HOSTS_FILE, ">",$hosts_file) or die "Could not open file '$hosts_file' $!";
open (my $PROTOS_FILE, ">", $protos_file) or die "Could not open file '$protos_file' $!";

my $cur_time=strftime "%F %T", localtime $^T;


my %http_add_ports;
my %https_add_ports;

my %ssl_hosts;
my %ssl_ip;

my $n_masked_domains = 0;
my %masked_domains;
my %domains;

my $sth = $dbh->prepare("SELECT * FROM zap2_ex_domains WHERE domain like '*.%'");
$sth->execute();
while (my $ips = $sth->fetchrow_hashref())
{
	my $dm = $ips->{domain};
	$dm =~ s/\*\.//g;
	$masked_domains{$dm} = 1;
}
$sth->finish();

$sth = $dbh->prepare("SELECT * FROM zap2_domains WHERE domain like '*.%'");
$sth->execute();
while (my $ips = $sth->fetchrow_hashref())
{
	my $dm = $ips->{domain};
	$dm =~ s/\*\.//g;
	my $domain_canonical=new URI("http://".$dm)->canonical();
	$domain_canonical =~ s/^http\:\/\///;
	$domain_canonical =~ s/\/$//;
	$domain_canonical =~ s/\.$//;
	$masked_domains{$domain_canonical} = 1;
	$n_masked_domains++;
	print $DOMAINS_FILE "*.",$domain_canonical,"\n";
	if($domains_ssl eq "true")
	{
		print $SSL_HOST_FILE "*.",$domain_canonical,"\n";
	}
}
$sth->finish();

$sth = $dbh->prepare("SELECT * FROM zap2_domains WHERE domain not like '*.%'");
$sth->execute;
while (my $ips = $sth->fetchrow_hashref())
{
	my $domain=$ips->{domain};
	my $domain_canonical=new URI("http://".$domain)->canonical();
	$domain_canonical =~ s/^http\:\/\///;
	$domain_canonical =~ s/\/$//;
	$domain_canonical =~ s/\.$//;
	my $skip = 0;
	foreach my $dm (keys %masked_domains)
	{
		if($domain_canonical =~ /\.\Q$dm\E$/ || $domain_canonical =~ /^\Q$dm\E$/)
		{
#			print "found mask $dm for domain $domain\n";
                	$logger->debug("found mask *.$dm for domain $domain\n");
			$skip++;
			last;
		}
	}
	next if($skip);

	$domains{$domain_canonical}=1;
	$logger->debug("Canonical domain: $domain_canonical");
	print $DOMAINS_FILE $domain_canonical."\n";
	if($domains_ssl eq "true")
	{
		next if(defined $ssl_hosts{$domain_canonical});
		$ssl_hosts{$domain_canonical}=1;
		print $SSL_HOST_FILE (length($domain_canonical) > 47 ? (substr($domain_canonical,0,47)."\n"): "$domain_canonical\n");
		my @ssl_ips=get_ips_for_record_id($ips->{record_id});
		foreach my $ip (@ssl_ips)
		{
			next if(defined $ssl_ip{$ip});
			$ssl_ip{$ip}=1;
			print $SSL_IPS_FILE "$ip","\n";
		}
	}
}
$sth->finish();

$sth = $dbh->prepare("SELECT * FROM zap2_urls");
$sth->execute;
while (my $ips = $sth->fetchrow_hashref())
{
	my $url2=$ips->{url};
	my $url1=new URI($url2);
	my $scheme=$url1->scheme();
	if($scheme !~ /http/ && $scheme !~ /https/)
	{
		my @ipp=split(/\:/,$url2);
		if(scalar(@ipp) != 3)
		{
			$logger->warn("Bad scheme ($scheme) for: $url2. Skip it.");
		} else {
			my @url_ips=get_ips_for_record_id($ips->{record_id});
			foreach my $ip (@url_ips)
			{
				print $HOSTS_FILE "$ip:",$ipp[2],"\n";
			}
		}
		next;
	}
	my $host=lc($url1->host());
	my $path=$url1->path();
	my $query=$url1->query();
	my $port=$url1->port();

	$host =~ s/\.$//;

	my $skip = 0;
	foreach my $dm (keys %masked_domains)
	{
		if($host =~ /\.\Q$dm\E$/ || $host =~ /^\Q$dm\E$/)
		{
#			print "found mask $dm for domain $host\n";
			$skip++;
			last;
		}
}

	my @ipp=split(/\:/,$url2);
	if(defined $domains{$host} & (scalar(@ipp) != "3"))
	{
		$logger->warn("Host '$host' from url '$url2' present in the domains");
		next;
	}

	if($scheme eq 'https')
	{
		next if(defined $ssl_hosts{$host});
		$ssl_hosts{$host}=1;
		print $SSL_HOST_FILE "$host\n";
		if($port ne "443")
		{
			$logger->info("Adding $port to https protocol");
			$https_add_ports{$port}=1;
		}
		my @ssl_ips=get_ips_for_record_id($ips->{record_id});
		foreach my $ip (@ssl_ips)
		{
			next if(defined $ssl_ip{$ip});
			$ssl_ip{$ip}=1;
			print $SSL_IPS_FILE "$ip","\n";
		}
		next;
	}
	if($port ne "80")
	{
		$logger->info("Adding $port to http protocol");
		$http_add_ports{$port}=1;
	}

	$url1->host($host);
	my $url11=$url1->canonical();

	$url11 =~ s/^http\:\/\///;
	$url2 =~ s/^http\:\/\///;

	my $host_end=index($url2,'/',7);
	my $need_add_dot=0;
#	$need_add_dot=1 if(substr($url2, $host_end-1 , 1) eq ".");

	# убираем любое упоминание о фрагменте... оно не нужно
	$url11 =~ s/^(.*)\#(.*)$/$1/g;
	$url2 =~ s/^(.*)\#(.*)$/$1/g;

	if((my $idx=index($url2,"&#")) != -1)
	{
		$url2 = substr($url2,0,$idx);
	}

	$url2 .= "/" if($url2 !~ /\//);

	$url11 =~ s/\/+/\//g;
	$url2 =~ s/\/+/\//g;

	$url11 =~ s/http\:\//http\:\/\//g;
	$url2 =~ s/http\:\//http\:\/\//g;

	$url11 =~ s/\/http\:\/\//\/http\:\//g;
	$url2 =~ s/\/http\:\/\//\/http\:\//g;

	$url11 =~ s/\?$//g;
	$url2 =~ s/\?$//g;

	$url11 =~ s/\/\.$//;
	$url2 =~ s/\/\.$//;
	$url11 =~ s/\//\.\// if($need_add_dot);
	insert_to_url($url11);
	if($url2 ne $url11)
	{
#		print "insert original url $url2\n";
		insert_to_url($url2);
	}
	make_special_chars($url11,$url1->as_iri(),$need_add_dot);
}
$sth->finish();

$sth = $dbh->prepare("SELECT ip FROM zap2_ips");
$sth->execute;
while (my $ips = $sth->fetchrow_hashref())
{
	my $ip=get_ip($ips->{ip});
	next if($ip eq "0.0.0.0" || $ip eq "0000:0000:0000:0000:0000:0000:0000:0000");
	if($ip =~ /(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/)
	{
		$ip_cidr->add_any($ip);
	} else
	{
		$ip6_cidr->add_any($ip);
	}

}
$sth->finish();

$sth = $dbh->prepare("SELECT ip FROM zap2_only_ips");
$sth->execute;
while (my $ips = $sth->fetchrow_hashref())
{
	my $ip=get_ip($ips->{ip});
	next if($ip eq "0.0.0.0" || $ip eq "0000:0000:0000:0000:0000:0000:0000:0000");
	if($ip =~ /(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/)
	{
		$ip_cidr_null->add_any($ip);
		$ip_cidr->add_any($ip);
	} else
	{
		$ip6_cidr_null->add_any($ip);
		$ip6_cidr->add_any($ip);
	}
}
$sth->finish();

$sth = $dbh->prepare("SELECT subnet FROM zap2_subnets");
$sth->execute;
while (my $ips = $sth->fetchrow_hashref())
{
	my $subnet = $ips->{subnet};
	if($subnet =~ /(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/)
	{
		$ip_cidr_null->add_any($subnet);
		$ip_cidr->add_any($subnet);
	} else
	{
		$ip6_cidr_null->add_any($subnet);
		$ip6_cidr->add_any($subnet);
	}
}
$sth->finish();

@ip_list=$ip_cidr->list();
%ip_s = map { $_ => 1 } @ip_list;
@ip6_list=$ip6_cidr->list();
%ip6_s = map { $_ => 1 } @ip6_list;
@ip_list_null=$ip_cidr_null->list();
%ip_s_null = map { $_ => 1 } @ip_list_null;
@ip6_list_null=$ip6_cidr_null->list();
%ip6_s_null = map { $_ => 1 } @ip6_list_null;

if(!$update_soft_quagga)
{
	foreach my $ip (@ip_list)
	{
		print $NET_FILE " network $ip\n";
	}
	if(@ip6_list)
	{
		print $NET_FILE "address-family ipv6\n";
		print $NET_FILE " neighbor $bgp6_neighbor activate\n";
		foreach my $ip (@ip6_list)
		{
			print $NET_FILE " network $ip\n";
		}
		print $NET_FILE "exit-address-family\n";
	}
	foreach my $ip (@ip_list_null)
	{
		print $NET_FILE "ip route $ip Null0\n";
	}
	foreach my $ip (@ip6_list_null)
	{
		print $NET_FILE "ip route $ip Null0\n";
	}
	print $NET_FILE "!\nline vty\n!\n\n";
	close $NET_FILE;
} else {
	analyse_quagga_networks();
}

my $n=0;
foreach my $port (keys %http_add_ports)
{
	print $PROTOS_FILE ($n == 0 ? "" : ","),"tcp:$port";
	$n++;
}
if($n)
{
	print $PROTOS_FILE "\@HTTP\n";
}

$n=0;
foreach my $port (keys %https_add_ports)
{
	print $PROTOS_FILE ($n == 0 ? "" : ","),"tcp:$port";
	$n++;
}
if($n)
{
	print $PROTOS_FILE "\@SSL\n";
}


close $DOMAINS_FILE;
close $URLS_FILE;
close $SSL_HOST_FILE;
close $HOSTS_FILE;
close $PROTOS_FILE;
close $SSL_IPS_FILE;

$dbh->disconnect();

my $domains_file_hash=get_md5_sum($domains_file);
my $urls_file_hash=get_md5_sum($urls_file);
my $ssl_host_file_hash=get_md5_sum($ssls_file);
my $net_file_hash=get_md5_sum($bgpd_file);

if(!$update_soft_quagga)
{
        if($net_file_hash ne $net_file_hash_old)
        {
                $logger->debug("Restarting bgpd...");
                system("/bin/systemctl", "restart","bgpd");
                if ( $? == -1 )
                {
                        $logger->error("Bgpd restart failed: $!");
                } else {
                        $logger->info("Bgpd successfully restarted!");
                }
        }
}

if($domains_file_hash ne $domains_file_hash_old || $urls_file_hash ne $urls_file_hash_old || $ssl_host_file_hash ne $ssl_host_file_hash_old)
{
        $logger->debug("Restarting nfqfilter...");

        system("/sbin/iptables -A FORWARD -s 192.168.30.4 -j DROP");
        sleep 3;
        system("/bin/systemctl", "restart","nfqfilter");
        sleep 10;
        system("/sbin/iptables -D FORWARD -s 192.168.30.4 -j DROP");
        if ( $? == -1 )
        {
                $logger->error("Nfqfilter restart failed: $!");
        } else {
                $logger->info("Nfqfilter successfully restarted!");
        }
}


sub get_md5_sum
{
	my $file=shift;
	open(my $MFILE, $file) or die "Can't open '$file': $!";
	binmode($MFILE);
	my $hash=Digest::MD5->new->addfile(*$MFILE)->hexdigest;
	close($MFILE);
	return $hash;
}

sub get_ips_for_record_id
{
	my $record_id=shift;
	my @ips;
	my $sql = "SELECT ip FROM zap2_ips WHERE record_id=$record_id";
	$sql="SELECT ip FROM zap2_ips WHERE record_id=$record_id AND resolved=0" if($only_original_ssl_ip eq "true");
	my $sth = $dbh->prepare($sql);
	$sth->execute;
	while (my $ips = $sth->fetchrow_hashref())
	{
		push(@ips,get_ip($ips->{ip}));
	}
	$sth->finish();
	return @ips;
}

sub get_ip
{
	my $ip_address=shift;
	my $d_size=length($ip_address);
	my $result;
	if($d_size == 4)
	{
		$result=ip_bintoip(unpack("B*",$ip_address),4);
	} else {
		$result=ip_bintoip(unpack("B*",$ip_address),6);
	}
	return $result;
}

sub analyse_quagga_networks
{
	my $need_save_config=0;

	my %ips_to_add = %ip_s;
	my %ips6_to_add = %ip6_s;
	my %ips_to_add_null=%ip_s_null;
	my %ips6_to_add_null=%ip6_s_null;

	my %ips_to_del;
	my %ips6_to_del;
	my %ips_to_del_null;
	my %ips6_to_del_null;

	foreach my $line (split /\n/ ,$show_run)
	{
		next if ($line =~ /^\s*\!/);
		if($line =~ /^\s*network\s+(.+)\/(\d+)/)
		{
			my $address=$1;
			my $mask=$2;
			my $ip_version=ip_get_version($address);
			my $ip_a = new Net::IP ("$address/$mask");
			my $ip_p = $ip_a->print();
			if($ip_version == 4)
			{
				 if(defined $ip_s{$ip_p})
				{
					delete $ips_to_add{$ip_p};
				} else {
					$ips_to_del{$ip_p}=1;
				}
			} elsif ($ip_version == 6)
			{
				if(defined $ip6_s{$ip_p})
				{
					delete $ips6_to_add{$ip_p};
				} else {
					$ips6_to_del{$ip_p}=1;
				}
			}
		}
		if($line =~ /^ip\s+route\s+(.+)\/(\d+)/)
		{
			my $address=$1;
			my $mask=$2;
			my $ip_version=ip_get_version($address);
			my $ip_a = new Net::IP ("$address/$mask");
			my $ip_p = $ip_a->print();
			if($ip_version == 4)
			{
				if(defined $ip_s_null{$ip_p})
				{
					delete $ips_to_add_null{$ip_p};
				} else {
					$ips_to_del_null{$ip_p}=1;
				}
			} elsif ($ip_version == 6)
			{
				if(defined $ip6_s_null{$ip_p})
				{
					delete $ips6_to_add_null{$ip_p};
				} else {
					$ips6_to_del_null{$ip_p}=1;
				}
			}
		}
	}

	if((scalar keys %ips_to_add) || (scalar keys %ips6_to_add) || (scalar keys %ips_to_add_null) || (scalar keys %ips6_to_add_null) || (scalar keys %ips_to_del) || (scalar keys %ips6_to_del) || (scalar keys %ips_to_del_null) || (scalar keys %ips6_to_del_null))
	{
		my ($rdr,$wtr);
		my $pid=open2($rdr,$wtr, "$vtysh");
		my $outb;
		print $wtr "configure terminal\n";
		$outb=<$rdr>;
		# delete routes
		foreach my $ip (keys %ips_to_del_null)
		{
			print $wtr "no ip route $ip Null0\n";
			$outb=<$rdr>;
		}

		foreach my $ip (keys %ips6_to_del_null)
		{
			print $wtr "no ip route $ip Null0\n";
			$outb=<$rdr>;
		}
		# add routes
		foreach my $ip (keys %ips_to_add_null)
		{
			print $wtr "ip route $ip Null0\n";
			$outb=<$rdr>;
		}
		foreach my $ip (keys %ips6_to_add_null)
		{
			print $wtr "ip route $ip Null0\n";
			$outb=<$rdr>;
		}
		print $wtr "router bgp $bgp_as\n";
		$outb=<$rdr>;
		# delete networks
		foreach my $ip (keys %ips_to_del)
		{
			print $wtr "no network $ip\n";
			$outb=<$rdr>;
		}
		# add networks
		foreach my $ip (keys %ips_to_add)
		{
			print $wtr "network $ip\n";
			$outb=<$rdr>;
		}
		print $wtr "address-family ipv6\n";
		foreach my $ip (keys %ips6_to_del)
		{
			print $wtr "no network $ip\n";
			$outb=<$rdr>;
		}
		foreach my $ip (keys %ips6_to_add)
		{
			print $wtr "network $ip\n";
			$outb=<$rdr>;
		}
		print $wtr "end\n";
		$outb=<$rdr>;
		print $wtr "write mem\n";
		$outb=<$rdr>;
		close($wtr);

		waitpid( $pid, 0 );
		my $child_exit_status = $? >> 8;
		if($child_exit_status)
		{
			$logger->error("Error while excecuting vtysh commands");
		} else {
			$logger->info("Quagga configuration successfully updated: added ".(scalar keys %ips_to_add)." ipv4 ips, added ".(scalar keys %ips6_to_add)." ipv6 ips, deleted ".(scalar keys %ips_to_del)." ipv4 ips, deleted ".(scalar keys %ips6_to_del)." ipv6 ips, added ".(scalar keys %ips_to_add_null)." ipv4 routes to blackhole, added ".(scalar keys %ips6_to_add_null)." ipv6 routes to blackhole, deleted ".(scalar keys %ips_to_del_null)." ipv4 routes from blackhole, deleted ".(scalar keys %ips6_to_del_null)." ipv6 routes from blackhole.");
		}
	}
}

sub _encode_sp
{
	my $url=shift;
	$url =~ s/\%7C/\|/g;
	$url =~ s/\%5B/\[/g;
	$url =~ s/\%5D/\]/g;
	$url =~ s/\%3A/\:/g;
	$url =~ s/\%3D/\=/g;
	$url =~ s/\%2B/\+/g;
	$url =~ s/\%2C/\,/g;
	$url =~ s/\%2F/\//g;
	return $url;
}

sub _encode_space
{
	my $url=shift;
	if($url =~ /\+/)
	{
		$url =~ s/\+/\%20/g;
		insert_to_url($url);
	}
	return $url;
}

sub make_special_chars
{
	my $url=shift;
	my $url1=$url;
	my $orig_rkn=shift;
	my $orig_url=$url;
	my $need_add_dot=shift;
	$url = _encode_sp($url);
	if($url ne $orig_url)
	{
		$logger->debug("Write changed url to the file");
		insert_to_url($url);
	}
	_encode_space($url);
	if($url =~ /\%27/)
	{
		$url =~ s/\%27/\'/g;
		$logger->debug("Write changed url (%27) to the file");
		insert_to_url($url);
	}
	_encode_space($url);
	if($url =~ /\%5C/)
	{
		$url =~ s/\%5C/\//g;
		$url =~ s/\/\/$/\//;
		$logger->debug("Write changed url (slashes) to the file");
		insert_to_url($url);
	}
	_encode_space($url);
	if($orig_rkn && $orig_rkn =~ /[\x{0080}-\x{FFFF}]/)
	{
		return if($orig_rkn =~ /^http\:\/\/[а-я]/i || $orig_rkn =~ /^http\:\/\/www\.[а-я]/i);
		$orig_rkn =~ s/^http\:\/\///;
		$orig_rkn =~ s/\//\.\// if($need_add_dot);
		$orig_rkn =~ s/^(.*)\#(.*)$/$1/g;
		$orig_rkn .= "/" if($orig_rkn !~ /\//);
		$orig_rkn =~ s/\/+/\//g;
		$orig_rkn =~ s/\?$//g;
		my $str = encode("utf8", $orig_rkn);
		Encode::from_to($str, 'utf-8','windows-1251');
		if($str ne $orig_rkn)
		{
			$logger->debug("Write url in cp1251 to the file");
			print $URLS_FILE $str."\n";
		}
		if($url ne $orig_rkn)
		{
			$logger->debug("Write changed url to the file");
			insert_to_url($orig_rkn);
		}
	}
}

sub insert_to_url
{
	my $url=shift;
	my $encoded=encode("utf8", $url);
	my $sum = md5($encoded);
	return if(defined $already_out{$sum});
	$already_out{$sum}=1;
	print $URLS_FILE $encoded."\n";
}
