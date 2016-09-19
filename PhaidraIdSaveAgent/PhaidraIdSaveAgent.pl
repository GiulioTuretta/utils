#!/usr/bin/env perl

=pod

=head1 PhaidraIdSaveAgent.pl (-since sinceepoch) (-irma-map-id mongooid)

  -since sinceepoch - check irma database for id records since this date
  -irma-map-id mongooid - process the irma record with this mongo-object-id

=cut

use strict;
use warnings;
use Data::Dumper;
$Data::Dumper::Indent= 1;
use POSIX qw(strftime);
use MongoDB;
use Mojo::Util qw(slurp);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::UserAgent;
use Mojo::URL;

my $configpath = 'PhaidraIdSaveAgent.json';
unless(-f $configpath){
	print "[".scalar localtime."] ", "Error: config path $configpath is not a file (or file does not exist). Usually $configpath would be a link to /etc/phaidra/...\n";
	system ("perldoc '$0'"); exit (0);
}
unless(-r $configpath){
	print "[".scalar localtime."] ", "Error: cannot access config: $configpath\n";
	system ("perldoc '$0'"); exit (0);
}

my $bytes = slurp $configpath;	
my $config = decode_json($bytes);

my $since;
my @irma_map_ids;
my $job_col;

while (defined (my $arg= shift (@ARGV)))
{
  if ($arg =~ /^-/)
  {
  	   if ($arg eq '-since') { $since = shift (@ARGV); }
  	elsif ($arg eq '-irma-map-id') { @irma_map_ids= @ARGV; @ARGV= (); }
	elsif ($arg eq '-jobs') { $job_col= shift (@ARGV); }
    else { system ("perldoc '$0'"); exit (0); }
  }
}

unless(defined($since) || @irma_map_ids || defined ($job_col)){
	print "[".scalar localtime."] ", "Error: Missing parameters.\n";
	system ("perldoc '$0'"); exit (0);
}


my $irma_mongo = MongoDB::MongoClient->new(host => $config->{irma_mongodb}->{host}, username => $config->{irma_mongodb}->{username}, password => $config->{irma_mongodb}->{password}, db_name => $config->{irma_mongodb}->{database})->get_database($config->{irma_mongodb}->{database});

if (defined ($job_col))
{
  my $mdb_job= $irma_mongo->get_collection ($job_col);
  my $job= $mdb_job->find_one();
  # print "job: ", Dumper ($job);

  my $irma_map_ids= $job->{'ids'};

  unless (defined ($irma_map_ids))
  {
    print "no jobs queued\n";
    exit;
  }

  @irma_map_ids= @$irma_map_ids;
  $mdb_job->remove ( { _id => $job->{_id} } );
}
print "irma_map_ids: ", join (' ', @irma_map_ids), "\n";

my %paf_dbs;

my $x_instance; # FIXME: there could be more instances; maybe each instance should be processed in one large loop

while( my( $instance, $value ) = each %{$config->{phaidra_instances}} ){	
	if(defined($value->{paf_mongodb})){
		$x_instance= $paf_dbs{$instance} = MongoDB::MongoClient->new(host => $value->{paf_mongodb}->{host}, username => $value->{paf_mongodb}->{username}, password => $value->{paf_mongodb}->{password}, db_name => $value->{paf_mongodb}->{database})->get_database($value->{paf_mongodb}->{database}); 
	}
}

# select the records
my @records;
my $col = $irma_mongo->get_collection('irma.map');
if(@irma_map_ids){

	foreach my $irma_map_id (@irma_map_ids)
	{
	print "[".scalar localtime."] ", "processing IRMA record id $irma_map_id\n"; 
	  my $id= (ref($irma_map_id) eq 'MongoDB::OID') ? $irma_map_id : MongoDB::OID->new(value => $irma_map_id);

	my $rec = $col->find_one({ '_id' => $id });
	push @records, $rec if defined $rec;
	}

}elsif(defined($since)){

	   if ($since eq 'yesterday') { $since= time()-86400; }
	elsif ($since =~ m#(\d+) days#) { my $days= $1; $since= time()-86400*$days; }

	my $find= {};
	if ($since > 0) { $find->{'_created'}= {'$gt' => $since }; }

	print "[".scalar localtime."] ", "processing IRMA records since $since [".strftime("%m/%d/%Y %H:%M:%S",localtime($since))."]\n"; 
	my $recs = $col->find($find);
	while (my $rec = $recs->next) {
		push @records, $rec if defined $rec;
	}	
}

# process the records
my $rec_cnt = scalar @records;
print "[".scalar localtime."] ", "found $rec_cnt records\n"; 

  my $emit_batch_event= 0;
  if ($rec_cnt >= 100 && defined($x_instance))
  {
    $emit_batch_event= $rec_cnt;
    emit_batch_event($x_instance, 'id_save_batch_started', 'batch_size' => $emit_batch_event);
  }

sleep(10);

my $i = 0;
for my $r (@records){
	$i++;

	# check if this id has a phaidra URL
	if (!exists($r->{url}) || !($r->{url} =~ /^http(s)?:\/\/([\w\.\-]+)\/(o:\d+)$/g)){
		print "[".scalar localtime."] ", "processing [$i/$rec_cnt] url[".$r->{url}."] not a phaidra url, skipping\n"; 
		next;
	}

	my $instance = $2;
	my $pid = $3;

	print "[".scalar localtime."] ", "processing [$i/$rec_cnt] pid=[$pid] hdl=[".$r->{hdl}."] instance=[$instance]\n"; 

	# only pick up id we support
	my @ids;
	if(exists($r->{hdl}) && $r->{hdl} ne ''){
		push @ids, {id => $r->{hdl}, type => 'hdl'};
	}
	if(exists($r->{urn}) && $r->{urn} ne ''){
		push @ids, {id => $r->{urn}, type => 'urn'};
	}
	unless(scalar @ids  > 0){
		print "[".scalar localtime."] ", "no known id found in the record, skipping\n"; 
		next;
	}

	for my $id (@ids){

		# check if id was saved
		my $has_id = has_id($config, $instance, $pid, $id);
		if(defined($has_id)){
			if($has_id ne ''){
				print "[".scalar localtime."] ", "$has_id already saved, skipping\n"; 
			}else{
				# save if it wasn't yet saved
				if(save_id($config, $instance, $pid, $id)){			
					# emit event for PAF	
					emit_event($paf_dbs{$instance}, $pid, $id, $r->{url}) if exists $paf_dbs{$instance};
				}
			}
		}else{
			print "[".scalar localtime."] ", "error getting object ids, skipping\n"; 
		}

	}	

}

  if ($emit_batch_event > 0)
  {
    emit_batch_event($x_instance, 'id_save_batch_finished', 'batch_size' => $emit_batch_event);
  }


exit(1);

sub has_id {
	my $config = shift;
	my $instance = shift;
	my $pid = shift;
	my $id = shift;

	my $action = "/object/$pid/id";
	my $url = Mojo::URL->new;
	$url->scheme('https');
	my @base = split('/',$config->{phaidra_instances}->{$instance}->{apibaseurl});
	$url->host($base[0]);	
	if(exists($base[1])){
		$url->path($base[1].$action);
	}else{
		$url->path($action);
	}

	my $ua = Mojo::UserAgent->new;
	my $tx = $ua->get($url);	
  	if (my $res = $tx->success) {  		
  		for my $oid (@{$res->json->{ids}}){
  			if($id->{type} eq 'hdl'){
  				if("hdl:".$id->{id} eq $oid){  				
  					return $oid;
  				}
  			}elsif($id->{type} eq 'urn'){
  				if($id->{id} eq $oid){  				
  					return $oid;
  				}
  			}  			
  		}
    	return '';
	}else{
		print "[".scalar localtime."] ", "ERROR searching for ids pid=[$pid]:\n"; 
		if($tx->res->json){
			if($tx->res->json->{alerts}){
				print Dumper($tx->res->json->{alerts})."\n";
			}
		}
		print Dumper($tx->error)."\n"; 		
		return undef;
	}
}

sub save_id {
	my $config = shift;
	my $instance = shift;
	my $pid = shift;
	my $id = shift;

	my $action = "/object/$pid/id/add?".$id->{type}."=".$id->{id};
	my $url = Mojo::URL->new;
	$url->scheme('https');
	$url->userinfo($config->{phaidra_instances}->{$instance}->{intcallusername}.":".$config->{phaidra_instances}->{$instance}->{intcallpassword});
	my @base = split('/',$config->{phaidra_instances}->{$instance}->{apibaseurl});
	$url->host($base[0]);	
	if(exists($base[1])){
		$url->path($base[1].$action);
	}else{
		$url->path($action);
	}

	my $ua = Mojo::UserAgent->new;
	my $tx = $ua->post($url);
  	if (my $res = $tx->success) {
  		print "[".scalar localtime."] ", "success\n"; 
    	return 1;
	}else{
		print "[".scalar localtime."] ", "ERROR adding id ".$id->{type}."[".$id->{id}."] pid=[$pid]:\n"; 
		if($tx->res->json){
			if($tx->res->json->{alerts}){
				print Dumper($tx->res->json->{alerts})."\n";
			}
		}
		print Dumper($tx->error)."\n"; 		
	}
}

sub emit_event {
	my $paf_mongo = shift;
	my $pid = shift;
	my $id = shift;
	my $url = shift;

	$paf_mongo->get_collection('events')->insert({
		ts_iso => ts_iso(), 
		event => 'id_save_finished',
		agent => 'phaidra_id_save',
		e => time, 
		pid => $pid,
		id => $id->{id},
		url => $url
	});
}

sub emit_batch_event {
	my $paf_mongo = shift;
	my $event= shift;

	$paf_mongo->get_collection('events')->insert({
		ts_iso => ts_iso(), 
		event => $event,
		agent => 'phaidra_id_save',
		e => time, 
		@_,
	});
}

sub ts_iso {
	my @ts = localtime (time());
	sprintf ("%04d%02d%02dT%02d%02d%02d", $ts[5]+1900, $ts[4]+1, $ts[3], $ts[2], $ts[1], $ts[0]);
}
