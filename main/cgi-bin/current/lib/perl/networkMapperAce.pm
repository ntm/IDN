package networkMapperAce;
use IO::Socket::UNIX qw( SOCK_STREAM );
use Data::UUID;
use Log::Log4perl qw(get_logger);
use Scalar::Util qw(blessed dualvar isweak readonly refaddr reftype tainted
                        weaken isvstring looks_like_number set_prototype);

use biomoleculeMapper;
use strict;

our $logger = get_logger ("networkMapper");
=pod TO DO
    - Add mapperSocket to networkObject
    
  *get rid of that  $mapableObject = $dataLayer->{ core };
  make of uniprot&co heritage of miscDataLayer
  *get rid of ugly json string (nodewriter)
    
    SPECIFICATIONS

  *linkData specs:       IE "richLink_1.0"
    link : {
    Adata : [
             ["Unique identifier for interactor A", ...  ],
             ["Alternative identifier for interactor A", ...  ],     
             ["Aliases for A", ...  ],                              
             ["NCBI Taxonomy identifier for interactor A", ...  ],    
             ["Biological role A", ...  ],                            
             ["Experimental role A", ...  ],                          
             ["Interactor type A", ...  ],                          
             ["Annotations for interactor A", ...  ],                 
             ["Xref for interactor A", ...  ],
             ["Stoichiometry for interactor A"],
             ["Participant identification method for interactor A"]
    ],
    Bdata : [
                ...  
                    ],
    iData : [
             ["Interaction detection methods", ... ],
             ["Identifier of the publication", ... ],
             ["Interaction types", ... ],
             ["Annotations for the interaction", ... ],
             ["Parameters of the interaction", ... ],
             ["Interaction identifier(s)", ... ]
            ] 
}   
 
    
    NODE MAPPING CASE CHECKED
    acedb : name, type, common
    uniprot: name, type, commo
    
    
    NOTE
    psicquic incoming data name are of the form 
    database:moleculeID we clean them.
    if we fail to fetch data from matrixDB we fall back to datalayer.
    added location => [] attributes in nodemapper from miscDataLayer::uniprot

   

    # NOTE TYPE is a simple string  could evolve to encompass more data notably genuine or inferred character    
=cut

use lib qw(lib/perl);

use strict;
use Data::Dumper;
use common;
use Ace 1.51;
use Ace::Browser::AceSubs qw(:DEFAULT DoRedirect);
use Ace::Browser::SearchSubs;
use JSON;
use miscDataLayer;
use matrixDB::interactionReport;
use psimi::interactionReport;
use miscAssociationLayer;
use matrixdbQuery;

=pod
    This module maps a list of biomolecule and their interactions in a json
    object embarking required attributes to be used in the networkt javascript module
    

  ---- networkNodes prototype ----
   	my $node = {
            index => scalar [Mandatory]
	    name => $biomoleculeName,
            common => "",                                  
            biofunc => "",
            tissue => [],
            uniprotKW => [],
	    pfam => [],
            tpm => [],
	    go => [],
	    gene => {
		geneName => [],
		synonym => [],
		uniGene => []
	    }, 	    
	    specie => "",	    
            type => "",
            relationship => {
		isFragmentOf => [],
		hasFragment => [],
		hasComponent => [],
		isComponentOf => [],
		boundTo => [] 
	    },
            location => [],
            id = ''
	};

     ---- networkEdges specifications ----
     link = {"source":0 ,"target":1, "type" : "boundTo/partOf/fragmentOf/association"},
=cut


=pod new
    Object constructor
    biomoleculeArray : list of matrixdb biomolecule identifier; [MANDATORY]
    interactionArray : list of biomolecule association; [OPTIONAL]
    AssociationObject (see asssociationObject.pm)
=cut
sub new {
        my $self = {};
        my $class = shift;
        bless $self, $class;
	
	my $p = common::arg_parser(@_);	

	$self->{ DB } = $p->{ DB };
	$self->{ nodeDataType } = 'LOCAL';
	# Mappers for node annotations and statistics
	$self->{ socketMappers } = {};
	$self->{ staticMappers } = {};
	# Data array and hash table accessors to it
	$self->{ links } = [];
	$self->{ nodeArray } = [];	
	$self->{ idLinkTable } = {};
	$self->{ nameLinkTable } = {};
	$self->{ idNodeTable } = {};  
	$self->{ nameNodeTable } =  {};  
	$self->{ networkData } = {}; # Statistic data container
	
	defined ($p->{ mappersSocketDef }) && $self->_setSockets ($p->{ mappersSocketDef });
	defined ($p->{ mappersFileDef }) && $self->_setMappers ($p->{ mappersFileDef });
	
	if (!defined($p->{ DB }) ) {
	    $logger->logdie("no valid arguments provided");
	    return;
	}
	
	$self->_fillingNodes (aceBiomoleculeList => $p->{ aceBiomoleculeList });
	$self->createNodeAccessors(); # reference node per id key && name
	
	return $self;
}
=pod createLinkAccessors 
    USE ONLY when network is reloaded from previous
    otherwise use createLink (push,register)
=cut
sub createLinkAccessors {
    my $self = shift;
    for (my $iLink = 0; $iLink < @{ $self->{ links } }; $iLink++ ) {
	my $link =  $self->{ links }->[ $iLink ];
	$logger->trace("reloading register $link->{ source } $link->{ target }");
	$logger->trace("reloading register $self->{ idNodeTable }->{ $link->{ source } }->{ name } " .
		       "$self->{ idNodeTable }->{ $link->{ target } }->{ name }");	
	$self->_registerLink (iName => $link->{ source }, jName => $link->{ target }, iLink => $iLink);
	my $refLink = $self->{ nameLinkTable }->{ $self->{ idNodeTable }->{ $link->{ source } }->{ name } }->{ $self->{ idNodeTable }->{ $link->{ target } }->{ name } };
	$logger->trace("content:\n" . Dumper($refLink));
    }
}

sub createNodeAccessors {
    my $self = shift;
    my $IDaccessor = {};
    my $nameAccessor = {};
    foreach my $node (@{$self->{ nodeArray }}) {
        $nameAccessor->{ $node->{ name }} = $node;
    }
    
    $logger->trace("ID accessor set");
    $self->{ nameNodeTable } = $nameAccessor;  
 
}

sub _setSockets {
    my $self = shift;
    my $socketDef = shift;
    
    $logger->info("reading socket mappers definition");
    my $info = "";
    foreach my $key (keys(%{$socketDef})) {
	my $socketPath = $socketDef->{ $key };
	$logger->info("$key socket : using Socket $socketPath");
	$self->{ socketMappers }->{ $key } = IO::Socket::UNIX->new(
	    Type => SOCK_STREAM,
	    Peer => $socketPath,
	    )
	    or $logger->logdie("Can't connect to server: $!");
	$info .= " $key ";
    }	
    
    $logger->info("successfully set [$info] sockets");    
}

=pod
mapper can be static (hash table) --> store under staticMapper attribute
    or objects -> base attribute of their own
=cut
sub _setMappers {
    my $self = shift;
    my $fileDef = shift;
    $logger->info("reading mappers file definition");
    my $info = "";
    foreach my $key (keys(%{$fileDef})) {
	if ($key eq "nameMutator") { 
	    $self->{ nameMutator } = biomoleculeMapper->new(template => $fileDef->{ $key });    
	    $logger->trace("name mutator successfully read from $fileDef->{ $key }");
	    next;	   
	}
	
	my $file = $fileDef->{ $key };
	open MAP, "<$file" or die $!;
	my $mapText = <MAP>;
	close MAP;    
	$self->{ staticMappers }->{ $key } = decode_json ($mapText);
    	$info .= " $key ";
    }	
    
    $logger->info("successfully set [$info] tree mappers");   
}

sub _pushLink {
    my $self = shift;
    my ($iName, $jName) = @_;
    my @list;
    
    my $id = scalar(@{$self->{ links }});
    push @{$self->{ links }}, {
	id => $id,
	source => $self->{ nameMutator }->mutateToRegular(key => $iName),
	target => $self->{ nameMutator }->mutateToRegular(key => $jName),
	type => "association" # boundTo/partOf/fragmentOf/association
    };
    $self->_registerLink(iName => $self->{ nameMutator }->mutateToRegular(key => $iName),
			 jName => $self->{ nameMutator }->mutateToRegular(key => $jName));
   # $logger->trace($list[0] . " - " . $list[1] . " LINK created");
}

sub _isKnownLink {
    my $self = shift;
    my $p = common::arg_parser (@_);
    
    if (common::slid($p->{ iName }, $p->{ jName })) {
	defined ($self->{ nameLinkTable }->{ $p->{ iName } }->{ $p->{ jName } }) && return 1;
    } elsif (common::slid($p->{ iNode }, $p->{ jNode }) ) {
	defined ($self->{ nameLinkTable }->{ $p->{ iNode }->{ name } }->{ $p->{ jNode }->{ name } }) && return 1;
    }
    
    return 0;
}


sub _getLink {
    my $self = shift;
    my $p = common::arg_parser (@_);
    my $link;
    if (common::slid($p->{ iName }, $p->{ jName })) {
	$link = $self->{ nameLinkTable }->{ $p->{ iName } }->{ $p->{ jName } };
	return $link;
    } elsif (common::slid($p->{ iNode }, $p->{ jNode }) ) {
	$link = $self->{ nameLinkTable }->{ $p->{ iNode }->{ name } }->{ $p->{ jNode }->{ name } };
	return $link;
    }
    
    $logger->error("Don't know how to get asked link, you provided:\n". Dumper($p));
    return;
}


=pod Create the basic source, target (int) attributes of each link
     Also create a LinkTable referencing all knwon links
=cut
sub _createLinks {
    my $self = shift;   
    my $p = common::arg_parser (@_);
    
    defined ($p->{ aceAssociationList }) || $logger->logdie("missing parameter");
    $logger->trace("COUCOU");
    foreach my $associationObject (@{$p->{ aceAssociationList }} ) {	    
	my $partnerArray = $self->_getAssociationPartners($associationObject);
	$self->_pushLink($partnerArray->[0]->name, $partnerArray->[1]->name);
    }
    $logger->trace("managed to create a " . scalar (@{$self->{ links }}) . " link attributes");
    #warn "managed to create a " . scalar (@{$self->{ links }}) . " link attributes";
    return;	 
    
}
=pod _registerLink Populates the $self->{ idLinkTable }, $self->{ nameLinkTable } attributes
    An optional argument iLink can be specified to reference a link somewhere in the linkArray
    otherwise the referenced link will be the last in the linkArray
=cut
sub _registerLink {
    my $self = shift;
    my $p = common::arg_parser(@_);
    my $iName = $p->{ iName };
    my $jName = $p->{ jName };
    my $iLink = defined ( $p->{ iLink } ) ? $p->{ iLink } : scalar(@{$self->{ links }}) - 1;
    
    $iName = $self->{ nameMutator }->mutateToRegular (key => $iName );
    $jName = $self->{ nameMutator }->mutateToRegular (key => $jName );
    
    $logger->trace(" i will add link $iName <> $jName");
    
    
    if (! defined ($self->{ nameLinkTable }->{ $iName })) {
	$self->{ nameLinkTable }->{ $iName } = { };
    } 
    $self->{ nameLinkTable }->{ $iName }->{ $jName } =  $self->{ links }->[ $iLink ];

    if (! defined ($self->{ nameLinkTable }->{ $jName })) {
	$self->{ nameLinkTable }->{ $jName } = { };
    }
    $self->{ nameLinkTable }->{ $jName }->{ $iName } = $self->{ links }->[ $iLink ];

}

=pod _jsonNodeNameFixer
A HACK TO RETURN STANDARD BIOMOLECULE NAME
create a hash table referencing a node by both its name and ist aceAccessor (if any)
then we loop over partner names in json data list aaData and replace any string by
the actual name of the node referenced through this string
=cut  
sub _jsonNodeNameFixer {
    my $self = shift;
    my $p = common::arg_parser (@_);
 
    my $target = $p->{ jsonString };
    
    $logger->warn("JSME::\n".$target);
    
    my $dataContainer = decode_json($target);    
    for (my $i = 0; $i < @{$dataContainer->{ aaData } }; $i++){
	for my $j (0,5) {
	    my $name = $self->{ nameMutator }->mutateToRegular (key => $dataContainer->{ aaData }->[$i]->[$j]);
	    $logger->trace("Proposed correction[col $j] " . 
			   $dataContainer->{ aaData }->[$i]->[$j] .
			   " --> $name");
	    $dataContainer->{ aaData }->[$i]->[$j] = $name;
	}
    }
    $target = encode_json($dataContainer);

   
    return $target

}

sub _jsonNodeNameFixerOld {
    my $self = shift;
    my $p = common::arg_parser (@_);

    my $target = $p->{ jsonString };
    
    
    my $shortCutNodePool = {};
    foreach my $node (@{$self->{ nodeArray }}) {
	$shortCutNodePool->{ $node->{ name } } = $node;
	if ($node->{ aceAccessor } =~ /[\S]+/) {
	    $shortCutNodePool->{ $node->{ aceAccessor } } = $node;
	}
    }
    $logger->trace("shortCut node pool:\n" . Dumper($shortCutNodePool));
    
    $logger->trace("Trying to load json object");
    my $dataContainer = decode_json($target);
    $logger->trace(Dumper($dataContainer));
    $logger->trace("Loading ok attempting to fix deprecated biomolecule name");
    for (my $i = 0; $i < @{$dataContainer->{ aaData } }; $i++){
	for my $j (0,5) {
	    my $name = $dataContainer->{ aaData }->[$i]->[$j];
	    my $altName = $shortCutNodePool->{ $name }->{ name };
	    $logger->trace("Proposed correction[col $j] $name --> $altName");
	    $dataContainer->{ aaData }->[$i]->[$j] = defined ($altName) ? $altName : $name;
	}
    }
    
    $target = encode_json($dataContainer);

    return $target
}

=pod addTo inject network description in a json object
=cut

sub addTo {
    my $self = shift;
    my $p = common::arg_parser(@_);
    

    if ($p->{ format } eq 'JSON') {
	my $jsonData = $self->getJSON ();
	
	my $targetJsonString = $p->{ target };
	$targetJsonString =~ s/}[\n\s]*$/,\n"network" : $jsonData\n}\n/;


	if (common::listExist($p->{ options }), 'nodeNameFixer') {
	    $targetJsonString = $self->_jsonNodeNameFixer( jsonString => $targetJsonString );
	}
	
	return $targetJsonString;
    }
  
}


=pod	index => sub {
	    my $node = shift;
	    my $key = shift;
	    ($node->{ $key } ne "") || return "";
	    return "\"$key\" : $node->{ $key },";
	},
=cut

sub summonLocalNodeWriter {
# nodes
    my $nodeWriter = {
	name => sub {
	    my $node = shift;
	    my $key = shift;
	    ($node->{ $key } ne "") || return "";
	    return "\"$key\" : \"$node->{ $key }\",";
	},
	id => sub {
	    my $node = shift;
	    my $key = shift;
	    ($node->{ $key } ne "") || return "";
	    return "\"$key\" : $node->{ $key },";
	},
	common => sub {
	    my $node = shift;
	    my $key = shift;
	    ($node->{ $key } ne "") || return "";
	    return "\"$key\" : \"$node->{ $key }\",";
	},
	biofunc => sub {
	    my $node = shift;
	    my $key = shift;
	    ($node->{ $key } ne "") || return "";
	    return "\"$key\" : \"$node->{ $key }\",";                            # Partially tested
	},
	tissue =>  sub {
	    my $node = shift;
	    my $key = shift;
	    (@{$node->{ $key }} > 0) || return "";	 
	    return "\"$key\" : [\"" .  join ('","', @{$node->{ $key }}) . "\"],";
	},
	uniprotKW => sub {
	    my $node = shift;
	    my $key = shift;
	    (@{$node->{ $key }} > 0) || return "";
	    return "\"$key\" : [\"" . join ('","', @{$node->{ $key }}) . "\"],";
	},
	pfam =>  sub {
	    my $node = shift;
	    my $key = shift;
	    (@{$node->{ $key }} > 0) || return "";
	    return "\"$key\" : [\"" . join ('","', @{$node->{ $key }}) . "\"],";
	},
	pdb =>  sub {
	    my $node = shift;
	    my $key = shift;
	    (@{$node->{ $key }} > 0) || return "";
	    return "\"$key\" : [\"" . join ('","', @{$node->{ $key }}) . "\"],";
	},
	molecularWeight => sub {
	    my $node = shift;
	    my $key = shift;
	    ($node->{ $key } ne "") || return "";
	    return "\"$key\" : \"$node->{ $key }\",";
	},
	tpm => sub {
	    my $node = shift;
	    my $key = shift;
	    (@{$node->{ $key }} > 0) || return "";
	    return "\"$key\" : [\"" .  join ('","', @{$node->{ $key }}) . "\"],";
	},
	go => sub {
	    my $node = shift;
	    my $key = shift;
	    (@{$node->{ $key }} > 0) || return "";
	    my $string = encode_json ($node->{ $key });
	    return "\"$key\": $string,";
	},
	gene => sub {
	    my $node = shift;
	    my $key = shift;
	    my $string = "";
	    for my $kw (qw /geneName synonym uniGene/) {
		(@{$node->{ $key }->{ $kw }} > 0) || return "";
		$string .= "\"$kw\":[\"" . join ('","', @{$node->{ $key }->{ $kw }}) . "\"],"; 
	    }
	    ($string eq "") && return $string;
	    $string =~ s/,$//;
	    return "\"$key\" : { $string },";
	},
	specie => sub {
	    my $node = shift;
	    my $key = shift;
	    ($node->{ $key } ne "") || return "";
	    return "\"$key\" : \"$node->{ $key }\",";
	},
	type => sub {
	    my $node = shift;
	    my $key = shift;	    
	    ($node->{ $key } ne "") || return "";
	    return "\"$key\" : \"$node->{ $key }\",";	    
	},
	relationship => sub {
	    my $node = shift;
	    my $key = shift;
	    my $string = "";
	    
	    for my $kw (qw /isFragmentOf hasFragment hasComponent isComponentOf boundTo/) {
		if (scalar (@{$node->{ $key }->{ $kw }}) == 0){
		    $string .= "\"$kw\":\[\],"; 
		    next;
		}	
		$string .= "\"$kw\":[\"" .  join ('","', @{$node->{ $key }->{ $kw }}) . "\"],"; 
	    }
	    ($string eq "") && return $string;
	    $string =~ s/,$//;
	    return "\"$key\" : { $string },";
	},
	betweenness => sub {
	    my $node = shift;
	    my $key = shift;
	    ($node->{ $key } ne "") || return "";
	    return "\"$key\" : \"$node->{ $key }\",";
	}
    };
    return $nodeWriter;
}

sub getJSON {
    my $self = shift;

    my $nodeWriter;
    if ($self->{ nodeDataType } eq 'LOCAL') { 
        $nodeWriter = summonLocalNodeWriter ();
    }
    if (! defined ($self->{ UItag })) {
	$self->setUID();
    }
    
    my $jsonData = "\"id\" : \"" . $self->{ UItag } . "\",\"nodeData\" : [";
    foreach my $node (@{$self->{ nodeArray }}) {
	my $nodeAsString;
	foreach my $key (qw /name common biofunc tissue uniprotKW pfam tpm go gene pdb specie type molecularWeight relationship central betweenness/) {
	    if ($key eq "central") {
		if (defined($node->{ $key })) {$nodeAsString .= '"central" : true,';}
		next; 
	    }
	    my $tmp = $nodeWriter->{ $key }($node, $key);	    	 	    
	    
	    $tmp eq "" && next;
	    $nodeAsString .= $tmp;
	}
	$nodeAsString =~ s/,$//;
	$jsonData .= "{$nodeAsString},\n";
    }
    $jsonData =~ s/,\n$/\n]\n/;
    if (@{$self->{ nodeArray }} == 0) {
	$jsonData = "\"nodeData\" : []\n";
    }

    $logger->trace("Empty Exepriment debug");
    foreach my $l (@{$self->{ links }}) {
	$logger->trace(Dumper($l));
    }
    

    # Add links
    if (@{$self->{ links }} > 0) {
	$logger->trace("About to encode link data structure:\n" . Dumper($self->{ links }));
	my $linkAsJSON = encode_json ($self->{ links });
	
	$linkAsJSON =~ s/("source":|"target":)"([\d]+)"/$1$2/g;


	$jsonData .= ",\"linksData\" : $linkAsJSON\n";	
    } else {
	$jsonData .= ",\"linksData\" : []\n";	
    }

    my @tmp;   
    foreach my $key (qw/upKeywordTree goKeywordTree/) {
	if (defined($self->{ networkData }->{ $key })) {
	    push @tmp, encode_json ($self->{ networkData }->{ $key }); 
	}	
    }
    $jsonData = @tmp > 0  ne "" ? "{$jsonData, \"networkData\" : [ ". join (",", @tmp) .  " ]}" : "{$jsonData, \"networkData\" : [] }";
    
    return $jsonData;
}

sub _extractInteractorName {
    my $self = shift;
    my $jsonObject = shift @_;

 #   open DBG, ">/tmp/jsonExtracter.dbg";
    my $dataContainer = decode_json($jsonObject);
  #  print DBG Dumper($dataContainer) . "\n";
 
   

  
    my @list;
    foreach my $assoc (@{$dataContainer->{ aaData }}) {
	push @list, $assoc->[0];
	push @list, $assoc->[5];
    }
    my $refArray = common::uniqList (\@list);
    
  #  print DBG Dumper($refArray);
  #  close DBG;
    return $refArray;
    #my @array = ($jsonObject)
}

=pod deleteLinks
    All links will be deleted but for one specified as argument
=cut

sub deleteLinks {
    my $self = shift;
    my $p = common::arg_parser(@_);

    my @nLinkArray;
    my $partnerPairList = $p->{ forceAssociationKeep }->getInteractorPairedList();	

    foreach my $partnerArray (@{ $partnerPairList }) {
	my $link = $self->{ nameLinkTable }->{ $partnerArray->[0] }->{ $partnerArray->[1] };
	if (!defined ($link) ) {
	    $logger->error("$partnerArray->[0] $partnerArray->[1] association not found in table");
	    next;
	}
	push @nLinkArray, $link;	
    }

    $logger->trace("deleted links array holds " . scalar(@nLinkArray) . " elements");
    $self->{ links } = \@nLinkArray;
}


=pod pruneLinks
    suppress link for which the source and / or the target node are not in the node list anymore    
=cut

sub pruneLinks {
    my $self = shift;
    
    my $newLinkList = [];


    $logger->trace(" ID ACCESSOR STATE:\n" . Dumper ($self->{ idNodeTable }));
    
    foreach my $pLink (@{ $self->{ links } }) {
	my $cnt = 0;
	foreach my $iKey (qw /source target/) {
	    my $nodeID = $pLink->{ $iKey };
	    $cnt = $self->{ idNodeTable }->{ $nodeID }->{ status } eq "active" ? $cnt + 1 : $cnt;
	}
	($cnt > 0) && push @{$newLinkList}, $pLink;
    }
    
    $logger->trace ("link pruning from " . scalar (@{ $self->{ links } }) . " to "
		    .  scalar (@{$newLinkList}) . " link elements");
    
    $self->{ links } = $newLinkList;    
}

=pod deleteNodes
    suppress a subset of nodes
    options can be specified to keep rest of the object intact
    we do not alter IDaccessor key will stiull exist but value will be undef
=cut 
sub deleteNodes {
    my $self = shift;
    my $p = common::arg_parser (@_);
    $logger->trace("TIMEprofile:(start)");     

    defined ($p->{ nodeNameList }) || die "missing parameters (node name list)";
    
    my @indexList;
    foreach my $name (@{ $p->{ nodeNameList }}) {
	my $i = $self->getNodeIndex (name => $name);
	if (!defined ($i)) {
	    $logger->error("deletable node named \"$name\" not found in current network!");
	    next;
	}
	push @indexList, $i; 
    }
    $logger->trace ("node index to delete [@indexList] (" .scalar (@indexList) . " elements)");
    my @descendingIndexList = sort { $b <=> $a } @indexList;
    
    $logger->trace("prior to deletion " . scalar (@{ $self->{ nodeArray }}));
    foreach my $index (@descendingIndexList) {
	$logger->trace("splicing at index $index ($self->{ nodeArray }->[$index]->{ name })");
	$self->{ nodeArray }->[$index]->{ status } = "removed";	    	
	splice (@{$self->{ nodeArray }}, $index, 1);	
    }
    $logger->trace("post deletion " . scalar (@{ $self->{ nodeArray }}));
    
    (common::listExist($p->{ options }, 'unTouchAll')) &&
	$logger->info("deleted " . scalar (@descendingIndexList) . " node and left the indexing intact");
    
    $logger->trace("TIMEprofile:(exit)");         
}

sub deleteAllNodes {
    my $self = shift;
=pod 
   for (my $index = 0; $index < @{ $self->{ nodeArray } }; $index++) {
	$self->{ nodeArray }->[$index]->{ status } = "removed";	    	
	splice (@{$self->{ nodeArray }}, $index, 1);	
    }
=cut
    $self->{ nodeArray } = [];
    $logger->trace("post deletion " . scalar (@{ $self->{ nodeArray }}));
}


=pod
    fill Go terms datastructure
    
=cut


sub getFreeID {
    my $self  = shift;

    my $i = 0;

    foreach my $node (@{$self->{ nodeArray }}) {
	if (!defined ($node->{ id })) {
	    $logger->error("current node does not have id attribute");	    
	    next;
	}
	$i = $i < $node->{ id } ? $node->{ id } + 1 : $i;
    }
    
    return $i;
}

sub computeStatistics {
    my $self = shift;
    my $p = common::arg_parser (@_);
    
    if (common::listExist($p->{ options }, 'reset')) {
	$self->computeUpKeywordTree ();
	return;
    }
    
    if (defined ($self->{ networkData }->{ upKeywordTree } )) {
	$logger->info("Uniprot keywork tree found, updating it");
    } else {
	$self->computeUpKeywordTree ();
    }
    
}

sub computeUpKeywordTree {
    my $self = shift;
    
    # access uniprot classification mapper
    my $mapperRoot = $self->{ staticMappers }->{ UniprotKW };
    
    $self->{ networkData }->{ upKeywordTree } = {
	name => 'Uniprot Keyword category',
	children => []	
    };    
    
    foreach my $category (@{$mapperRoot->{ children }}) {
	my $node = {
	    name => $category->{ name },
	    children => [],
	    memberID => []}
	;
	my @tmp;
	foreach my $upKW (@{$category->{ children }}) {
	    $upKW->{ memberID } = [];
	    $upKW->{ memberRef } = [];
	    
	    foreach my $node (@{$self->{ nodeArray }}) {
		if (common::listExist ($node->{ uniprotKW }, $upKW->{ AC })) {
		    push @{$upKW->{ memberID }}, $node->{ name }; 
		    push @tmp, $node->{ name };
		}
	    }
	    (@{$upKW->{ memberID }} == 0) && next;
 	    push @{$node->{ children }}, $upKW;
	}	
	
	$node->{ memberID } = common::uniqList (\@tmp);
	push @{$self->{ networkData }->{ upKeywordTree }->{ children }}, $node;
    }

    $logger->trace("TIMEprofile:(exit)");     
    $logger->info("uniprot Keyword Tree Mapper Data structure\n" 
		  . Dumper($self->{ networkData }->{ upKeywordTree }));

}

=pod
    return a datastructure sorting all uniprot keyword occurences
    preprocessing for the client navigator
=cut
sub getUpKeywordTree {
    my $self = shift;
    defined ($self->{ networkData }->{ upKeywordTree }) && return $self->{ networkData }->{ upKeywordTree }; 

    $logger->error ("accessing network element for an uncomputed uniprot Keyword metadata");
    return;
}



=pod fill all biomolecule related fields
    TODO : miscDataLayer fall back failure, handle/skip the data mapping
 
=cut
sub _fillingNodes {
    my $self = shift;
    my $p = common::arg_parser (@_);
    
    my $sTime = common::getTime();
    $logger->trace("Starting the filling of " . scalar (@{$p->{ aceBiomoleculeList }}) );     
		   
    
    my $cnt = 0;

    foreach my $biomoleculeObject (@{$p->{ aceBiomoleculeList }}) {
	$cnt++;

	my $biomoleculeName = $self->{ nameMutator }->mutateToMatrixdb (key => $biomoleculeObject->name);
	# the target container
	my $node = {
	    name => '',
	    molecularWeight => '',
	    aceAccessor => '', # for meta types
            common => "",                                  # Partially tested
            biofunc => "",
            tissue => [],
            uniprotKW => [],                               # now a list of {id:"", term:""}
	    pfam => [],
            tpm => [],
	    go => [],                                      # now a list of {id:"", term:""}
	    betweenness => 0, # number of association where biomolecule is reported --> hyperlink to association page
	    gene => {
		geneName => [],
		synonym => [],
		uniGene => []
	    }, 	    
	    specie => "",	    
            type => "",
            relationship => {
		isFragmentOf => [],
		hasFragment => [],
		hasComponent => [],
		isComponentOf => [],
		boundTo => [] 
	    },
	    id => "",
	    pdb => []
	};
	# Set the original object and summon its mapper
	my $mapper = summonLocalDataMapper();
	


#	my @tmpAceObjects = $self->{ DB }->fetch (-query => "query find biomolecule $biomoleculeName");
#	my $aceObject = scalar(@tmpAceObjects) > 0 ? shift @tmpAceObjects : undef;
	my $aceObject = $biomoleculeObject;

	my $mapableObject;
	$logger->info("mapping data for node named $biomoleculeName");

	# We should not have to mutate molecule name to regular
	if (!defined ($aceObject)){
	    $logger->warn("no ace object fetched for NODE \"$biomoleculeName\" try to fall back to miscDataLayer");	  
	    my $dataLayer = miscDataLayer->new(name => $biomoleculeName);	    
	    defined ($dataLayer) 
		? $logger->warn ("successfully fetch Object named \"$biomoleculeName\" from miscDatalayer")
		: $logger->warn ("was unable to fetch Object named \"$biomoleculeName\" from miscDatalayer");
	    $mapper = $dataLayer->summonDataMapper(template => $node);
	    $mapableObject = $dataLayer->getCoreObject();
	} else {
	    $mapableObject = $aceObject;
	}
	
	$logger->trace("index num $cnt \"$biomoleculeName\"");

	$self->_setNodeIdentity(node => $node, string => $biomoleculeName, 
				dataObject => $mapableObject);
	
	# Fill the container
	$logger->trace("Node to fill is :\n" . Dumper($node));
	foreach my $key (keys (%{$node}))  {
	    $logger->trace("FILLING : $node->{ name } ". $key);
	    
	    ($key eq "aceAccessor") && next;
	    
	    ($key ne "common"    && $key ne "biofunc" && $key ne "pdb" &&
	     $key ne "uniprotKW" && $key ne "go"      && 
	     $key ne "specie"  &&  $key ne "molecularWeight" && $key ne "relationship" &&
	     $key ne "tissue" && $key ne "betweenness") && next; ## developement purpose
	    
	    ($key eq "name" || $key eq "type" || 
	     $key eq "tpm" || $key eq "tissue")  && next;
	    $logger->trace("FILLED OK");
	    $node->{ $key } = $mapper->{ $key }($mapableObject);
	}

	# Deal with the go and uniprot hash table
	my @goContainerList = ();
	foreach my $term (@{$node->{ 'go' }}) {
	    if ($term !~ /GO:[\d]+/) {
		$logger->warn ("Not at valid GO term \"$term\" involved data structure is \n" . Dumper($node));
		next;
	    }
	   
	    my $goContainer;
	    #my $goContainer = localSocket::runGoRequest(with => $self->{ socketMappers }->{ 'GO' }, 
	    #	 					type => 'goNodeSelector', selectors => { id => $term });
	    defined $goContainer || next;
	    push @goContainerList, $goContainer;
	}
	$node-> { 'go' } = \@goContainerList;
	
	$logger->trace("node Lookup\n". Dumper ($node));

	# NOTE TYPE is a simple string  could evolve to encompass more data notably genuine or inferred character
	my $tmpName = $self->{ nameMutator }->mutateToMatrixdb(key => $node->{ name }); 
	
	if ($tmpName =~ /^MULT/) {
	    $node->{ type } = 'multimer'; 
	} elsif ($tmpName =~ /^CAT/) {
	    $node->{ type } = 'cation'; 
	} elsif ($tmpName =~ /^PFRAG/) {
	    $node->{ type } = 'fragment'; 
	} elsif ($tmpName =~ /^LIP/) {
	    $node->{ type } = 'lipid'; 
	} elsif ($tmpName =~ /^GAG/) {
	    $node->{ type } = 'glycosaminoglycan'; 
	} elsif (common::isUniprotID(string => $tmpName)) {
	    $node->{ type } = 'protein'; 
	} else {	
	    $node->{ type } = 'biomolecule'; 
	}
	# Store the node	
	$node->{ status } = 'active';	
	push @{$self->{ nodeArray }}, $node;	
    }

    $logger->trace("filled node array content:\n" . Dumper ($self->{ nodeArray }));
    
    $logger->trace("subroutine time stamps:\n\tstart:$sTime\n\tstop:".common::getTime());
    
}

=pod LocalMapper(MATRIXDB STORAGE)
    attribute must match canonical node attributes
    
=cut
sub summonLocalDataMapper {
    my $localMapper = {
	aceAccessor => sub {
	    my $aceObject = shift @_;
	    foreach my $string (qw/Molecule_Processing CheBI_identifier EBI_xref/) {
		my ($val) = $aceObject->get($string);
		(defined($val)) && return $val;
	    }
	    return '';
	},
	common => sub {
	    my $aceObject = shift @_;
	    my $map = "";
	    foreach my $string (qw/Multimer_Name Other_Multimer_Name FragmentName Other_Fragment_Name Common_Name Other_Name GAG_Name Other_GAG_Name Cation_Name Glycolipid_Name Phospholipid_Name Inorganic_Name Other_Inorganic_Name/) {
		my ($val) = $aceObject->get($string);
		if (defined($val)) {
		    $map .= "$val, ";
		}
	    }
	    $map =~ s/, $//;
	    return $map;
	},
	biofunc => sub {
	    my $aceObject = shift @_;
	    my $map = "";
	    foreach my $string (qw/Function GAG_Structure Zone Other_informations Molar_MassGAG Location More_info Stoichiometry Definition/) {		
		my ($val) = $aceObject->get($string);
		if (defined($val)) {
		    $map .= "$val, ";
		}
	    }
	    $map =~ s/, $//;
	    return $map;
	},
	betweenness => sub {
	    my $aceObject = shift @_;
	    my @val = $aceObject->get('Association');
	    return scalar (@val);
	},
	uniprotKW => sub {
	    my $aceObject = shift @_;
	    my @val = $aceObject->get('Keywrd');
	    my @array;
	    foreach my $kw (@val) {
		push @array, $kw->name;
	    }
	    return \@array;
	},
	molecularWeight => sub {
	    my $aceObject = shift @_;
	    my ($val) = $aceObject->get("Molecular_Weight");	    
	    my $string = defined ($val) ? $val->name : "";
	    return $string;
	},
	go => sub {
	    my $aceObject = shift @_;
	    return [];  # Debugging purpose
	    my @val = $aceObject->get('GO');
	    my @array;
	    foreach my $go (@val) {
		push @array, $go->name;
	    }
	    return \@array;	   
	},
	specie => sub {
	    my $aceObject = shift @_;
	    my ($val) = $aceObject->get("In_Species");	    
	    my $string = defined ($val) ? $val->name : "";
	    return $string;
	},
	pfam => sub {
	    my $aceObject = shift @_;
	    my @val = $aceObject->get('Pfam');
	    my @array;
	    foreach my $dom (@val) {
		push @array, $dom->name;
	    }
	    return \@array;	    
	},
	pdb => sub {
	    my $aceObject = shift @_;
	    my @val = $aceObject->get('PDB');
	    my @array;
	    foreach my $dom (@val) {
		push @array, $dom->name;
	    }
	    return \@array;
	},
	relationship => sub {
	    my $aceObject = shift @_;

	    my $miniMap = { # aceDB key => network key
		Belongs_to => "isFragmentOf",
		ContainsFragment => "hasFragment",
		Component => "hasComponent",
		In_multimer => "isComponentOf",
		Bound_Coval_to => "boundTo" 		    
	    };
	    my $container = {
		isFragmentOf => [],
		hasFragment => [],
		hasComponent => [],
		isComponentOf => [],
		boundTo => [] 	
	    };
	    
	    my ($subTree) = $aceObject->at('Relationships');
	    while (defined ($subTree)) {
		my @col = $subTree->col(); 		
		foreach my $val (@col) {
		    $logger->trace("THIS IS A TEST " . $subTree->name . " --> ". $val->name);		    
		    push @{$container->{ $miniMap->{ $subTree->name } }}, $val->name;
		}		
		$subTree = $subTree->down();
	    }	    
	    $logger->trace("THIS IS ALL " . Dumper($container));
	    return $container;
	},
	gene => sub {	  
	    my $aceObject = shift @_;
	    my $container = {
		geneName => [],
		synonym => [],
		uniGene => []
	    };
	    warn "geneseeker " . $aceObject->name;
	    foreach my $geneTag (keys (%{$container})) { #
		my $subTree = $aceObject->get($geneTag);
		(defined ($subTree)) || next;
		warn "$geneTag SubFound::" . $subTree->asAce();
		my @col = $subTree->col();		
		foreach my $val (@col) {
		    push @{$container->{ $geneTag }}, $val->name;
		}
	    }	    
	    return $container;
	}

    };
    
    return $localMapper;
}


sub getNodeIndex {
    my $self = shift;
    my $p = common::arg_parser (@_);
    
    (defined ($p->{ name })) || return;
    
    

    my $i = 0;
    my @buffer;
    foreach my $node (@{$self->{ nodeArray }}) {
#	$logger->trace("(" . $p->{ name } . ") iam looking at " . Dumper($node));
	push @buffer, $node->{ name };
	($p->{ name } eq $node->{ name } ) && return $i;
	$i++;
    }


    $logger->error("node index not found for $p->{ name }\nfaced node name list was:\n"
		  . Dumper(@buffer));
    
    return; 
}



sub addNodeAttributes {
    my $self = shift;
    my $p = common::arg_parser (@_);
    if (defined($p->{ nodeAceList })){
	#$logger->trace('toutotu');
	foreach my $obj (@{ $p->{ nodeAceList } }){
#	    $logger->trace("yess" . Dumper($obj));
	    my $name = $obj->name;
	    my $node = $self->{ nameNodeTable }->{ $name };
	 
#	    $logger->trace("i amm here" . Dumper($self->{ nodeNameTable }));
	    defined($node) || next;	    
	    $logger->trace("setting node $name as new center");
	    foreach my $key (keys(%{$p->{ attributes } })){
		$node->{ $key } = $p->{ attributes }->{ $key };
	    }
	}
	return;
    }

    
    foreach my $option (@{ $p->{ attr } }) {
	if ($option eq "id") {
	    foreach my $node (@{$self->{ nodeArray }}) {
		$node->{ id } = $self->getNodeIndex (name => $node->{ name });
	    }	
	}
    }
    
}

sub getNodeNameList {
     my $self = shift;
    
     my $nameList = [];
     foreach my $node (@{$self->{ nodeArray }}) {
	 push @{$nameList},  $node->{ name };
     }
     
     return $nameList;
}

sub getLinkInteractorList {
    my $self = shift;
    
    my $nameList = [];
    foreach my $link (@{$self->{ links }}) {
	my $node = $self->getNodeAsID (id => $link->{ source });
	my $molA = $node->{ name };	
	$node = $self->getNodeAsID (id => $link->{ target });
	my $molB = $node->{ name };
	push @{$nameList}, [$molA, $molB];
    }
    
    return $nameList;
}

sub dumper {
    my $self = shift;
    my $file = shift;
    my @dumpAttr = qw (nameLinkTable idLinkTable nameNodeTable idNodeTable);
    my $string = "Network Data Dumper\n";
    foreach my $attribute (@dumpAttr) {
	$string .= "\n\nDumping $attribute\n";	
	if ($attribute =~ /LinkTable/) {
	    foreach my $key (keys (%{$self->{ $attribute }})) {
	
		foreach my $subKey (keys (%{$self->{ $attribute }->{ $key }})) {
		    my $link = $self->{ $attribute }->{ $key }->{ $subKey };
		    $string .= " $key $subKey -(link)-> " . Dumper($link);
		}
	    }
	}
	elsif ($attribute =~ /NodeTable/) {
	    foreach my $key (keys (%{$self->{ $attribute }})) {
		my $node = $self->{ $attribute }->{ $key };
		$string .= "$key -(node)-> " . Dumper ($self->{ $attribute }->{ $key });
	    }
	}	
    }
    $logger->trace("writingDump");
    open OUT, ">$file" or die $!;
    print OUT $string;
    close OUT;	

}

sub getNode {
    my $self = shift;
    my $p = common::arg_parser (@_);
    
    defined ( $p->{ name }) && return $self->{ nameNodeTable }->{ $p->{ name } };

    return;
}


sub getNodeAsID {
    my $self = shift;
    my $p = common::arg_parser (@_);
    defined ($self->{ idNodeTable }->{ $p->{ id }}) &&
	return $self->{ idNodeTable }->{ $p->{ id }};
    
    $logger->warn("node ID $p->{ id } not found in IDaccessor table");
    foreach my $node (@{$self->{ nodeArray }}) {
	 ($node->{ id } == $p->{ id }) && return $node;	 
    }
    $logger->error ("No node found for id $p->{ id }");

    return;
}

=pod add link element to an preexisting network
    first create link
    then supplement data to edges
    mergedAssociationObject argument must be provided
=cut
sub addLink {
    my $self = shift;
    my $p = common::arg_parser(@_);
    $logger->trace("add link routine " . Dumper($p));
    defined ($p->{ aceAssociationList }) || $logger->logdie("missing parameter");
    $self->_createLinks (aceAssociationList => $p->{ aceAssociationList });
    $self->addLinkData(template => $p->{ template }, 
		       aceAssociationList => $p->{ aceAssociationList }
	);
}


=pod supplement biological data to egdes
    by attaching to each link the proper data container 
    coping with the specified format.
    Two sources can be combined, local & psimi object list (presumably out of a psicquic query)
=cut
sub addLinkData {
    my $self = shift;
    my $p = common::arg_parser (@_);
    $logger->trace("TIMEprofile:(start)");     
    my $sTime = common::getTime();
    my $dataTemplate; 
    $logger->trace("fIn " . $p->{ template });
 
    open JSON ,"< " . $p->{ template } or die $!;
    my @jsonStr = <JSON>; 
    close JSON;
    
    $dataTemplate = decode_json(join ('', @jsonStr));		
    
    foreach (my $cnt = 0; $cnt < @{$p->{ aceAssociationList }}; $cnt++) {
	my $aceAssociation = $p->{ aceAssociationList }->[$cnt];
	
	my $partners = $self->_getAssociationPartners($aceAssociation);
	my $molA = $self->{ nameMutator }->mutateToRegular(key => $partners->[0]);
	my $molB = $self->{ nameMutator }->mutateToRegular(key => $partners->[1]);
	
	my $link = $self->_getLink(iName => $molA, jName => $molB);

	$logger->trace("biomolecule couple $molA $molB");
	$logger->trace(Dumper($link) );


	!defined($link) &&
            $logger->logdie("Link { $molA $molB } not found in network:\n" . Dumper ($self->{ nameLinkTable }));
	
	my $linkObject = matrixDB::interactionReport::fetchAssociation (
	    DB => $self->{ DB },
	    template => $dataTemplate, 
	    molA => $self->{ nameMutator }->mutateToMatrixdb(key => $molA),
	    molB => $self->{ nameMutator }->mutateToMatrixdb(key => $molB),
	    socketCv => $self->{ socketMappers }->{ 'MI' }
	    );

	(!defined $linkObject) && $logger->logdie("Link { $molA $molB } returned empty Object\n");
	$link->{ details } = $linkObject;
	
#        $logger->trace("Object Link w/ filled details reference and content " . $molA . " " . 
#		       $molB . " :\n" . Dumper ($link->{ details }) );
	
    }
#    $logger->info("Final link data set (" . scalar(@{$self->{ links }}) . "):");

    foreach my $obj (@{$self->{ links }}) {
	$logger->trace(Dumper ($obj) ) ;
    }

    $logger->trace("subroutine time stamps:\n\tstart:$sTime\n\tstop:".common::getTime());    
}

sub setUID {
    my $self = shift @_;
    my $ug  = new Data::UUID;
    my $uuid = $ug->create();
    $self->{ UItag } = $ug->to_string( $uuid );
}

=pod setNodeIdentity
    This method try to enforce the use of a common/regular node name
    where node->{ name } are 
    PRO features leads to ${UNIPROTID}-PRO_XXXXXXXX
    CHEBI compound CHEBI:XXXX
    MULTIMER 

=cut
sub _setNodeIdentity {
    my $self = shift;
    my $p = common::arg_parser (@_);
    my $node = $p->{ node };
    
    if ($self->{ nameMutator }->isMatrixdbRegistred(key => $p->{ string })) {
	$node->{ aceAccessor } = $p->{ string };
	$node->{ name } = $self->{ nameMutator }->mutateToRegular(key => $p->{ string });
	return;
    } elsif ($self->{ nameMutator }->isRegularRegistred(key => $p->{ string })) {
	$node->{ name } = $p->{ string };
	$node->{ aceAccessor } = $self->{ nameMutator }->mutateToMatrixdb(key $p->{ string });
	return;
    }
    $node->{ name } = $p->{ string };
    
    $logger->trace('returning' . Dumper($node));
    
    return ;
}

sub _getAssociationPartners {
    my $self = shift;
    
    my $aceAssociation = shift;
    my $partners = $aceAssociation->get('biomolecule');
    my @col = $partners->col();
    if (@col == 1) {
	push (@col, $col[0]);
    }
    
    return \@col;
}

1;
