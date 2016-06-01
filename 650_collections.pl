#!/usr/bin/perl -w

use strict;
use warnings;

use Data::Dumper;
use lib;
use JSON;
use utf8;
use MongoDB;
use Encode;

use YAML::Syck;
use Mojo::Base 'Mojolicious';
use Mojo::ByteStream qw(b);



sub getParentFolderId($);
sub getUwmetadata($$$);
sub createFolderCollection($$);

my @folderCollections;


my $config = YAML::Syck::LoadFile("/etc/phaidra.yml");

my $fedoraadminuser  = $config->{"fedoraadminuser"};
my $fedoraadminpass = $config->{"fedoraadminpass"};
my $phaidraapibaseurl  = $config->{"phaidraapibaseurl"};

my @base = split('/',$phaidraapibaseurl);
my $scheme = "https";


#use sandbox API
#$fedoraadminpass = 'xxxxxxx';
#$base[0] = 'services.phaidra-sandbox.univie.ac.at';


my $url = Mojo::URL->new;
$url->scheme($scheme);
$url->host($base[0]);

if(exists($base[1])){
         $url->path($base[1]."/collection/create/");
}else{
         $url->path("/collection/create/");
}
$url->userinfo("$fedoraadminuser:$fedoraadminpass");
my $ua = Mojo::UserAgent->new;



my $defaultDescription = 'Die Universität Wien feierte im Jahr 2015 ihr 650. Gründungsjubiläum. Aus diesem Anlass öffnete eine der ältesten und größten Hochschulen Europas ihre Tore einer breiten Öffentlichkeit. Die vielfältigen Fachbereiche, Fakultäten und Zentren der Universität begleiteten das Jubiläumsjahr mit zahlreichen Aktivitäten. Das Angebot beinhaltete Vorträge, Kongresse und Symposien, Spezialvorlesungen und Seminare aber auch Ausstellungen, Konzerte, Sportevents und Performances. Die Vermittlung der Relevanz von Forschung und Lehre stand dabei im Mittelpunkt.';

my $mongoDbConnection = MongoDB::MongoClient->new(
        #host => "mongodb://mongo.example.com/",
        host => 'localhost',
        username => '',
        password => '',
);

my $mongoDb = $mongoDbConnection->get_database('bagger');
my $collectionBags = $mongoDb->get_collection('bags');
my $collectionFolders = $mongoDb->get_collection('folders');

my $datasetBags = $collectionBags->find({'$and' => [{'folderid'=> { '$regex' => '.*Fotos'}}, {'project' => '650jahren'}]});

my $metadata;
my $metadataDir;
my $myFolders = {};
my $myFoldersDir = {};
#my $k = 0;
while (my $bag = $datasetBags->next){
     my $stringFotos = substr($bag->{folderid}, -5);
     
     if( ($stringFotos eq 'Fotos') && ( not defined $myFolders->{$bag->{folderid}})){
           $myFolders->{$bag->{folderid}} = 1;
           my $datasetFotos = $collectionBags->find({'$and' => [ {'folderid'=> $bag->{folderid}}, {'project'  => '650jahren'}]});
           my $i = 0;
           $metadata->{members} = ();
           while (my $fotos = $datasetFotos->next){
                 my $member;
                 $member->{pid} = $fotos->{jobs}[0]->{pid};
                 $member->{'pos'} = $i;
                 push @{$metadata->{members}}, $member;
                 my @sourceFileArray = split /\//, $fotos->{SourceFile};
                 my $fileName = pop @sourceFileArray;
                 my $folderName = pop @sourceFileArray;
                 $metadata->{metadata}->{uwmetadata} = getUwmetadata($folderName, $defaultDescription, 'Universität Wien' );
                 $metadata->{metadata}->{members} = $metadata->{members};
                 $i++;
           }
           print 'processing foto'."\n";
           print Dumper($metadata->{metadata}->{members});

                
           my $json_str = b(encode_json({ metadata => $metadata->{metadata}  }))->decode('UTF-8');
           print "foto url:", $url,"\n";    
           my $tx2 = $ua->post($url => form => { metadata => $json_str } );
           if (my $res2 = $tx2->success) {
                print Dumper("foto post success.", $tx2->res->json);
                #exit;
                if(defined $tx2->res->json->{pid}){
                       my $parentFolderId = getParentFolderId($bag->{folderid});
                       createFolderCollection($tx2->res->json->{pid}, $parentFolderId);
                }
                #exit;
                #$k++;
                #exit if $k>2;
           }else {
                if(defined($tx2->res->json)){
                    if(exists($tx2->res->json->{alerts})) {
                           print Dumper("foto uwmetadata: alerts: ",$tx2->res->json->{alerts});        
                    }else{
                           print Dumper("foto uwmetadata: json: ",$tx2->res->json);        
                    }
                }else{
                    print Dumper("foto uwmetadata: ",$tx2->error);        
                }
           }
     }
}

print "\n\nFolder collections:",Dumper(@folderCollections);


sub getParentFolderId($){
     
     my $folderId = shift;
     
     my $parentFolderId;
     my $datasetBagsFolder = $collectionFolders->find({'$and' => [{'folderid'=> $folderId}, {'project' => '650jahren'}]});
     while (my $folderId = $datasetBagsFolder->next){
             my @folderPathArray = split /\//, $folderId->{path};
             my $fotoFolder = pop @folderPathArray;
             my $parentFolder = join('/', @folderPathArray);
             my $datasetBagsFolderParent = $collectionFolders->find({ '$and' => [{'path'=> $parentFolder}, {'project' => '650jahren'}]});
             while (my $folderIdParent = $datasetBagsFolderParent->next){
                    $parentFolderId = $folderIdParent->{folderid};
             }
     }
     return $parentFolderId;
}



sub createFolderCollection($$){

    my $pid = shift;
    my $parentFolderId = shift;
        
    my $datasetBagsDir = $collectionBags->find({'$and' => [{'folderid'=> $parentFolderId}, {'project' => '650jahren'}]});
    my $metadataDir;
    $metadataDir->{members} = ();
    my $memberFolder;
    $memberFolder->{'pos'} = 0;
    $memberFolder->{'pid'} = $pid;
    push @{$metadataDir->{members}}, $memberFolder;

    my $i = 1;
    while (my $bag = $datasetBagsDir->next){
                 print 'createFolderCollection path:',Dumper($bag->{path});
                 my $memberFolder2;
                 $memberFolder2->{pid} = $bag->{jobs}[0]->{pid};
                 $memberFolder2->{'pos'} = $i;
                 push @{$metadataDir->{members}}, $memberFolder2;
                 my @sourceFileArray = split /\//, $bag->{path};
                 my $fileName = pop @sourceFileArray;
                 my $folderName = pop @sourceFileArray;
                 $metadataDir->{metadata}->{uwmetadata} = getUwmetadata($folderName, $defaultDescription, 'Universität Wien' );
                 $metadataDir->{metadata}->{members} = $metadataDir->{members};
                 $i++;
    }
    
    print 'createFolderCollection processing'."\n";
    print Dumper($metadataDir->{metadata}->{members});
                
    my $json_str = b(encode_json({ metadata => $metadataDir->{metadata}  }))->decode('UTF-8'); 
    my $tx2 = $ua->post($url => form => { metadata => $json_str } );
    if (my $res2 = $tx2->success) {
                print Dumper("createFolderCollection  post success.", $tx2->res->json);
                push @folderCollections, $tx2->res->json->{pid};
    }else {
                if(defined($tx2->res->json)){
                    if(exists($tx2->res->json->{alerts})) {
                           print Dumper("createFolderCollection uwmetadata: alerts: ",$tx2->res->json->{alerts});        
                    }else{
                           print Dumper("createFolderCollection uwmetadata: json: ",$tx2->res->json);        
                    }
                }else{
                    print Dumper("createFolderCollection uwmetadata: ",$tx2->error);        
                }
    }
}



sub getUwmetadata($$$){

     my $uwmetaTitle = shift;
     my $uwmetaDescription = shift;
     my $creator = shift;
     my @fileNameArray;
     my $fileExtension;
      
            
     my $institutionNode = '{
                    "xmlns": "http://phaidra.univie.ac.at/XML/metadata/lom/V1.0/entity",
                    "xmlname": "institution",
                    "input_type": "input_text",
                    "ui_value": "'.$creator.'",
                    "datatype": "CharacterString"
                  },
                  {
                    "xmlns": "http://phaidra.univie.ac.at/XML/metadata/lom/V1.0/entity",
                    "xmlname": "type",
                    "input_type": "input_text",
                    "ui_value": "institution",
                    "datatype": "CharacterString"
                  }
                  ';
      
      my $uwmeta_string = '
      [
      {
        "xmlns": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0",
        "xmlname": "general",
        "children": [
          {
            "xmlns": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0",
            "xmlname": "title",
            "ui_value": "'.$uwmetaTitle.'",
            "value_lang": "de",
            "datatype": "LangString"
          },
          {
            "xmlns": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0",
            "xmlname": "language",
            "ui_value": "de",
            "datatype": "Language"
          },
          {
            "xmlns": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0",
            "xmlname": "description",
            "ui_value": "'.$uwmetaDescription.'",
            "value_lang": "de",
            "datatype": "LangString"
          }
        ]
      },
      {
        "xmlns": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0",
        "xmlname": "lifecycle",
        "children": [
          {
            "xmlns": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0",
            "xmlname": "contribute",
            "data_order": "0",
            "ordered": 1,
            "children": [
              {
                "xmlns": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0",
                "xmlname": "role",
                "ui_value": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0\/voc_3\/1552095",
                "datatype": "Vocabulary"
              },
              {
                "xmlns": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0",
                "xmlname": "entity",
                "data_order": "0",
                "ordered": 1,
                "children": ['.$institutionNode.']
              }
            ]
          }
        ]
      },
      {
        "xmlns": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0",
        "xmlname": "rights",
        "children": [
          {
            "xmlns": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0",
            "xmlname": "license",
            "ui_value": "http:\/\/phaidra.univie.ac.at\/XML\/metadata\/lom\/V1.0\/voc_21\/1",
            "datatype": "License"
          }
        ]
      }
    ]


      ';
      
    my $json_bytes = encode('UTF-8', $uwmeta_string);
    my $uwmeta_hash = JSON->new->utf8->decode($json_bytes);
        
    return $uwmeta_hash;
      
}


1;