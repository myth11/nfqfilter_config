#!/usr/bin/perl

# создаем нужные файлы из БД rkn
# Внимание!!! IP адреса в базе должны храниться в виде байт, а не целого числа.

use strict;
use warnings;
use Config::Simple;
use DBI;
use File::Basename;
use URI;
use Net::Nslookup;
use POSIX;
use Digest::MD5;
use Log::Log4perl;
use Net::IP qw(:PROC);

use utf8;
my $dir = File::Basename::dirname($0);

my $Config = {};
Config::Simple->import_from($dir.'/rkn.conf', $Config) or die "Can't open ".$dir."/rkn.conf for reading!\n";
Log::Log4perl::init( $dir."/rkn_log.conf" );

my $logger=Log::Log4perl->get_logger();


my $db_host = $Config->{'DB.host'} || die "DB.host not defined.";
my $db_user = $Config->{'DB.user'} || die "DB.user not defined.";
my $db_pass = $Config->{'DB.password'} || die "DB.password not defined.";
my $db_name = $Config->{'DB.name'} || die "DB.name not defined.";

my @resolvers = $Config->{'NS.resolvers'} || ();

# пути к генерируемым файлам:
my $bgpd_file = $Config->{'BGP.quagga_config'} || "";
my $domains_file = $Config->{'APP.domains'} || "";
my $urls_file = $Config->{'APP.urls'} || "";
my $ssls_file = $Config->{'APP.ssls'} || "";
my $hosts_file = $Config->{'APP.hosts'} || "";
my $protos_file = $Config->{'APP.protocols'} || "";
my $domains_ssl = $Config->{'APP.domains_ssl'} || "false";
$domains_ssl = lc($domains_ssl);

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
my %ipv6_nets;

my $domains_file_hash_old=get_md5_sum($domains_file);
my $urls_file_hash_old=get_md5_sum($urls_file);
my $ssl_host_file_hash_old=get_md5_sum($ssls_file);
my $net_file_hash_old=get_md5_sum($bgpd_file);

open (my $DOMAINS_FILE, ">",$domains_file) or die "Could not open file '$domains_file' $!";
open (my $URLS_FILE, ">",$urls_file) or die "Could not open file '$urls_file' $!";
open (my $SSL_HOST_FILE, ">",$ssls_file) or die "Could not open file '$ssls_file' $!";


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


my @http_add_ports;
my @https_add_ports;

my %ssl_hosts;

my $sth = $dbh->prepare("SELECT * FROM zap2_domains");
$sth->execute;
while (my $ips = $sth->fetchrow_hashref())
{
	my $domain=$ips->{domain};
	my $domain_canonical=new URI("http://".$domain)->canonical();
	$domain_canonical =~ s/^http\:\/\///g;
	$domain_canonical =~ s/\/$//g;
	$logger->debug("Canonical domain: $domain_canonical");
	print $DOMAINS_FILE $domain_canonical."\n";
	if($domains_ssl eq "true")
	{
		next if(defined $ssl_hosts{$domain_canonical});
		$ssl_hosts{$domain_canonical}=1;
		print $SSL_HOST_FILE "$domain_canonical\n";
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
	my $host=$url1->host();
	my $path=$url1->path();
	my $query=$url1->query();
	my $port=$url1->port();
	if($scheme eq 'https')
	{
		next if(defined $ssl_hosts{$host});
		$ssl_hosts{$host}=1;
		print $SSL_HOST_FILE "$host\n";
		if($port ne "443")
		{
			$logger->info("Adding $port to https protocol");
			push(@https_add_ports,$port);
		}
		next;
	}
	if($port ne "80")
	{
		$logger->info("Adding $port to http protocol");
		push(@http_add_ports,$port);
	}

	$host =~ s/\.$//;
	$url1->host($host);

	my $url11=$url1->canonical();

	$url11 =~ s/^http\:\/\///;

	# убираем любое упоминание о фрагменте... оно не нужно
	$url11 =~ s/^(.*)\#(.*)$/$1/g;

	print $URLS_FILE "$url11\n";
	make_special_chars($url11);
}
$sth->finish();

$sth = $dbh->prepare("SELECT ip FROM zap2_ips");
$sth->execute;
while (my $ips = $sth->fetchrow_hashref())
{
	my $ip=get_ip($ips->{ip});
	next if(defined $ip_s{$ip});
	$ip_s{$ip}=1;
}
$sth->finish();



parse_our_blacklist($Config->{'APP.blacklist'} || "");



if(!$update_soft_quagga)
{
	foreach my $ip (keys %ip_s)
	{
		my $ip_version=ip_get_version($ip);
		if($ip_version == 4)
		{
			print $NET_FILE " network $ip/32\n";
		} elsif ($ip_version == 6)
		{
			$ipv6_nets{$ip}=1;
		} else {
			$logger->error("Unknown ip version for ip $ip");
		}
	}

	if(keys %ipv6_nets)
	{
		print $NET_FILE "address-family ipv6\n";
		print $NET_FILE " neighbor $bgp6_neighbor activate\n";
		foreach my $ip (keys %ipv6_nets)
		{
			print $NET_FILE " network $ip/128\n";
		}
		print $NET_FILE "exit-address-family\n";
	}

	print $NET_FILE "!\nline vty\n!\n\n";
	close $NET_FILE;
} else {
	analyse_quagga_networks();
}

my $n=0;
foreach my $port (@http_add_ports)
{
	print $PROTOS_FILE ($n == 0 ? "" : ","),"tcp:$port";
	$n++;
}
if($n)
{
	print $PROTOS_FILE "\@HTTP\n";
}

$n=0;
foreach my $port (@https_add_ports)
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
	system("/bin/systemctl", "restart","nfqfilter");
	if ( $? == -1 )
	{
		$logger->error("Nfqfilter restart failed: $!");
	} else {
		$logger->info("Nfqfilter successfully restarted!");
	}
}


sub parse_our_blacklist
{
	my $file=shift;
	my @urls;
	if(open (my $our_f,"<",$file))
	{
		while(my $line=<$our_f>)
		{
			chomp $line;
			push(@urls,$line);
		}
		close($our_f);
	} else {
		warn "Could not open file '$file' $!";
		return ;
	}
#	print $NET_FILE " ! ip's from our blacklist\n";
	foreach my $url (@urls)
	{
		my $url1=new URI($url);
		my $scheme=$url1->scheme();
		if($scheme !~ /http/ && $scheme !~ /https/)
		{
			$logger->warn("bad scheme for: $url. Skip it.");
			next;
		}
		my $host=$url1->host();
		my $path=$url1->path();
		my $query=$url1->query();
		my $port=$url1->port();
		my @adrs = ();
		eval
		{
			@adrs = nslookup(domain => $host, server => @resolvers, timeout => 4 );
		};
#		print $NET_FILE " ! host: $host\n" if(@adrs);
		foreach my $ip (@adrs)
		{
			next if(defined $ip_s{$ip});
			$ip_s{$ip}=1;
			#print $NET_FILE " network $ip/32\n";
		}
		if($scheme eq 'https')
		{
			next if(defined $ssl_hosts{$host});
			$ssl_hosts{$host}=1;
			print $SSL_HOST_FILE "$host\n";
			if($port ne "443")
			{
				$logger->info("Need to add another port for ssl $port");
			}
			next;
		}
		if($port ne "80")
		{
			$logger->info("Need to add another port for http $port");
		}
		my $url11=$url1->canonical();
		$url11 =~ s/http\:\/\///g;
		print $URLS_FILE "$url11\n";
		make_special_chars($url11);
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
	my $sth = $dbh->prepare("SELECT ip FROM zap2_ips WHERE record_id=$record_id");
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
	my $added_ip=0;
	my $deleted_ip=0;
	my %ips_to_add=%ip_s;
	foreach my $line (split /\n/ ,$show_run)
	{
		next if ($line =~ /^\s*\!/);
		if($line =~ /^\s*network\s+(.+)\/(\d+)/)
		{
			my $address=$1;
			my $mask=$2;
			my $ip_version=ip_get_version($address);
			my $ip_a = new Net::IP ($address);
			if(defined $ip_s{$ip_a->ip()})
			{
				delete $ips_to_add{$ip_a->ip()};
			}
			if (!exists( $ip_s{$ip_a->ip()})) # удаляем из bgpd
			{
				my $del_cmd="$vtysh -c 'configure terminal' -c 'router bgp $bgp_as'";
				if($ip_version == 4)
				{
				} elsif ($ip_version == 6)
				{
					$del_cmd .= " -c 'address-family ipv6'";
				} else {
					$logger->error("Unknown ip version for ip $address");
					next;
				}
				$del_cmd .= " -c 'no network $address/$mask'";
				$logger->debug("Delete ip address $address from bgpd via vtysh");
				my $output=`$del_cmd`;
				if ( $? == -1 )
				{
					$logger->error("Error while executed cmd $del_cmd: $!");
				} else {
					$need_save_config++;
					$deleted_ip++;
					$logger->debug("Command '$del_cmd' excecuted successfully");
				}
			}
		}
	}
	foreach my $ip (keys %ips_to_add)
	{
		my $ip_version=ip_get_version($ip);
		my $add_cmd="$vtysh -c 'configure terminal' -c 'router bgp $bgp_as'";
		my $mask="32";
		if($ip_version == 4)
		{
		} elsif ($ip_version == 6)
		{
			$add_cmd .= " -c 'address-family ipv6'";
			$mask="128";
		} else {
			$logger->error("Unknown ip version for ip $ip");
			next;
		}
		$add_cmd .= " -c 'network $ip/$mask'";
		$logger->debug("Add ip address $ip to bgpd via vtysh");
		my $output=`$add_cmd`;
		if ( $? == -1 )
		{
			$logger->error("Error while executed cmd $add_cmd: $!");
		} else {
			$need_save_config++;
			$added_ip++;
			$logger->debug("Command '$add_cmd' excecuted successfully");
		}
	}
	if($need_save_config)
	{
		my $output=`$vtysh -c 'write mem'`;
		if ( $? == -1 )
		{
			$logger->error("Unable to write Quagga configuration: $!");
		} else {
			$logger->info("Quagga configuration successfully saved: added $added_ip ips, deleted $deleted_ip ips");
		}
	}
}

sub make_special_chars
{
	my $url=shift;
	if($url =~ /\%7C/)
	{
		my $dup_url=$url;
		$dup_url =~ s/\%7C/\|/g;
		print $URLS_FILE "$dup_url\n";
		$logger->debug("Found %7C at url it replaced with '|' and added to file\n");
	}
	if($url =~ /\+/)
	{
		my $dup_url=$url;
		$dup_url =~ s/\+/\%20/g;
		print $URLS_FILE "$dup_url\n";
		$logger->debug("Found '+' at url it replaced with %20 and added to file\n");
	}
}
