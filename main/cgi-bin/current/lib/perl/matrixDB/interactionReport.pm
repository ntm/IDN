package matrixDB::interactionReport;

use Data::Dumper;
use strict;
use common;
use JSON;
use Scalar::Util qw(blessed dualvar isweak readonly refaddr reftype tainted
                        weaken isvstring looks_like_number set_prototype);
use Log::Log4perl qw(get_logger :levels);
use localSocket;
use customNetwork;

my $logger = get_logger("matrixDB::interactionReport");
$logger->level($ERROR);

#    return all association ace object linked to a particular biomolecule
#     returns : [
#           {
#	    name => $biomolecule,
#	    associations => []
#           },
#            ...
#    ]


our $CV_SOCKET;


#    given a aceperl get query returns the value of a scalar or in case of an 
#    attached object, the name of the object
sub getAceScalar {
    my $p = common::arg_parser (@_);
    common::slid($p->{ aceObject }, $p->{ key }) || die "unproper arguments";
    
    (my $class = blessed ($p->{ aceObject })) || die "not a ace object";
    
    my $ptr;
    if (! defined ($p->{ pos })) {
	$ptr = $p->{ aceObject }->get ($p->{ key });
    } else {
	$ptr = $p->{ aceObject }->get ($p->{ key }, $p->{ pos });	
    }
    # query failed
    defined ($ptr) || return;
    
    # query success, return scalar or deferenced object and return name
    if (my $subClass =  blessed ($ptr)) {
	return $ptr->name;
    }
    
     return $ptr;
 }

 sub getAssociation {
     my $p = common::arg_parser (@_);
     ( ! common::slid ($p->{ mutatorObject }, $p->{ dataType }, 
		       $p->{ biomoleculePair }, $p->{ DB }) 
       &&
       ! common::slid ($p->{ mutatorObject }, 
		       $p->{ dataType }, 
		       $p->{ biomoleculeArray },$p->{ DB }) 
     ) && die "wrong parameters types";
     
     $logger->trace("TIMEprofile:(start)");     
     
     my $nameMutator = $p->{ mutatorObject };
     
     my $associationsData = [];    

#late addition pairwise interaction check
     if (defined ($p->{ biomoleculePair })) {
	 my $biomoleculeOne = $nameMutator->mutateToMatrixdb(key => $p->{ biomoleculePair }->[0]);
	 my $biomoleculeTwo = $nameMutator->mutateToMatrixdb(key => $p->{ biomoleculePair }->[1]);
	 my $requestArray = [ "query find Association ${biomoleculeOne}__${biomoleculeTwo};", "query find Association ${biomoleculeTwo}__${biomoleculeOne};" ];
	 
	 foreach my $request (@{ $requestArray }) {
	     my $container = {
		 name => $nameMutator->mutateToRegular(key => $p->{ biomoleculePair }->[0]),
		 associations => []
	     };	 
	     my @assocObjects = $p->{ DB }->fetch (-query=> $request);
	     foreach my $aceAssociation (@assocObjects) {
		 my $partners = $aceAssociation->get('biomolecule');
		 my @col = $partners->col();
#	    warn "======>@col";
		 if (@col == 1) {
		     push (@col, $col[0]);
		 }
		 my @tmp;
		 foreach my $aceBiomolecule (@col) {
		     push @tmp, $nameMutator->mutateToRegular(key => $aceBiomolecule->name);
		 }
		 push @{$container->{ associations }}, \@tmp;
	     }
	     push @{$associationsData}, $container;
	 }
	 return $associationsData;

#    Bypass classical biomolecule based research
     } elsif (defined ($p->{ customNetworkInput })) {
	 if (@{$p->{ customNetworkInput }} > 0) {
	     my $customInput = $p->{ customNetworkInput }->[0];

	     $logger->trace("customInput found " . Dumper($customInput));
	     
	     my $Kw = []; # keywords array
	     foreach my $elem (@{$customInput->{ kw }}) {
		 foreach my $term (keys(%{$elem})) {
		     push @{$Kw}, $elem->{ $term };
		 }
	     }
	     $logger->trace(Dumper($Kw));
	     my $customDataContainer = customNetwork::query(localKeyWords => $customInput->{ compartment },
							    uniprotKeywords => $Kw, 
							    diseaseListString => 0, 
							    tissueList => $customInput->{ tissue },
							    tpmTreshold => $customInput->{ tpm },
							    strictBool => 0, # disabled for now
							    database=> $p->{ DB }
		 );
	     $logger->trace("tagHERE");
	     $logger->trace(Dumper($customDataContainer));
	     foreach my $interactor (@{$customDataContainer->{ interactor } }) {
		 	 my $container = {
			     name =>  $nameMutator->mutateToRegular(key => $interactor->{ name }),
			     associations => []
			 };
			 foreach my $index (@{$interactor->{ ref }}) {
			     my $aceAssociation = $customDataContainer->{ association }->[$index];
			     my $partners = $aceAssociation->get('biomolecule');
			     my @col = $partners->col();
			     if (@col == 1) {
				 push (@col, $col[0]);
			     }
			     my @tmp;
			     foreach my $aceBiomolecule (@col) {
				 push @tmp, $nameMutator->mutateToRegular(key => $aceBiomolecule->name);
			     }
			     push @{$container->{ associations }}, \@tmp;			     
			 }
			 push @{$associationsData}, $container;
	     }
	     
	     $logger->trace("association report from custom\n:" . Dumper($associationsData));
	 
	 return $associationsData;
     }} 

#    Classic biomolecule based search
     foreach my $biomolecule (@{$p->{ biomoleculeArray }}) {
	 $biomolecule = $nameMutator->mutateToMatrixdb(key => $biomolecule);
	 my $request = "query find biomolecule $biomolecule;follow Association;";
	 my $container = {
	     name => $nameMutator->mutateToRegular(key => $biomolecule),
	     associations => []
	 };
	 my @assocObjects = $p->{ DB }->fetch (-query=> $request);
	 foreach my $aceAssociation (@assocObjects) {
	     my $partners = $aceAssociation->get('biomolecule');
	     my @col = $partners->col();
#	    warn "======>@col";
	     if (@col == 1) {
		 push (@col, $col[0]);
	     }
	     my @tmp;
	     foreach my $aceBiomolecule (@col) {
		 push @tmp, $nameMutator->mutateToRegular(key => $aceBiomolecule->name);
	     }
	     push @{$container->{ associations }}, \@tmp;
	 }
	 push @{$associationsData}, $container;
     }
    
     $logger->trace("TIMEprofile:(exit)");     
     return $associationsData;
}

#UNUSED
#    provided a set of lists of molecule names
#    extract from a getAssociation interaction report the set of molecule not in lists
#    (from => $associationData, notFoundIn => [ $wholeBiomoleculeList, $activeBiomoleculeList]);
#return a list of names
sub extractNewPartner {
    my $p = common::arg_parser (@_);
    #flatten the partner list;
    my $partnerList = [];

    foreach my $association (@{$p->{ from }->{ associations }}) {
	foreach my $mol (@{$association}) {
	    push @{$partnerList}, $mol;
	}
    }
    $partnerList = common::uniqList ($partnerList);
    
    my $newMoleculeList = [];
    foreach my $list ($p->{ notFoundIn }) {
	foreach my $candidateMol (@{$list}) {
	    (common::listExist ($partnerList, $candidateMol)) && next;
	    push @{$newMoleculeList}, $candidateMol;
	} 
    }
    
    return $newMoleculeList;    
}

# fetchAssociation
#    returns a linkObject which is specified by the template parameters
#    eg: rich_link_1.0 where:
#    any "dummy" key value in template assumes a straight mapping between 
#    the key and matrixDB tag
#    any dummyCV expects ask for a MI identifier (that we fetch from local server)
sub fetchAssociation {   
    my $p = common::arg_parser (@_);
    
    ( defined ($p->{ name }) || 
      (common::slid($p->{ molA }, $p->{ molB })) 
    )|| die "unable to guess molecule name from supplied arguments";

    if (! defined($p->{ socketCv } )){
	$logger->error("Undefined socket provided as argument");
    } else {
	$CV_SOCKET = $p->{ socketCv } ;	   
    }
    if (!defined($p->{ name })) {
	$logger->trace("matrix db association fetching \"$p->{ molA }__$p->{ molB }\"");     
    } else {
	$logger->trace("matrix db association fetching \"$p->{ name }\"");     
    }
    my $mapper = getMapper ($p->{ template });

#    my $container = $mapper->{ associationDescriptor } ($mapper, 
#							$p->{ template }, $p->{ DB }
#							, $p->{ molA }, $p->{ molB });     

    my $container;
    if (defined ($p->{ name }) ){
	$container = $mapper->{ associationDescriptor } (
	    mapper => $mapper, template => $p->{ template },
	    DB => $p->{ DB }, name => $p->{ name });
    } else {
	$container = $mapper->{ associationDescriptor } (
	    mapper => $mapper, template => $p->{ template },DB => $p->{ DB },
	    molA => $p->{ molA }, molB => $p->{ molB });
    }
   
    $logger->trace("matrixdb fetch association data content:\n" . Dumper($container));
    
    return $container;
}

#    MATRIXDB interaction mapper
#    template version returns a collection of subroutines handling the 
#    data field filling
sub getMapper {
    my $template = shift;
    (defined ($template->{ version })) || die "No version found in mapper template";

    $logger->info("getting mapper for matrixdb to " . $template->{ version });
    if ($template->{ version } eq "nutshell_1.0") {
	return {
	    associationDescriptor => sub {		
                my $p = common::arg_parser(@_);
	    
		# move to template level
		my $nodeTemplate = $p->{ template }->{ associationDescriptor };
		# spawn a copy of the datastructure to be filled
		my %hash = %{$nodeTemplate};    
		my $container = \%hash;

		my $rawQuery;
                my @answerSet;
                if (defined($p->{ name })) {
		     $rawQuery = "query find Association $p->{ name }";
                     @answerSet = $p->{ DB }->fetch (-query => $rawQuery);
		} else {
		    $rawQuery = "query find Association $p->{ molA }__$p->{ molB }";
		     @answerSet = $p->{ DB }->fetch (-query => $rawQuery);
                     if (@answerSet == 0) {
		         $rawQuery = "query find Association $p->{ molB }__$p->{ molA }";
		         @answerSet = $p->{ DB }->fetch (-query => $rawQuery);
		     }		
		     if (@answerSet == 0) {
		         $logger->error("Empty matrixdb association Set for $p->{ molB } -- $p->{ molA }");
		         return;
		     }		
		     if (@answerSet > 1) {
		         $logger->warn ("more than one association found for following couple -> $p->{ molB } -- $p->{ molA }");
		     }
		}
		my $aceObject = shift (@answerSet);
		$container->{ name } = $aceObject->name;

		return $container;
	    }
	};
    }
    
    if ($template->{ version } eq "richLink_1.0") {
	return {
	    associationDescriptor => sub {	
		my $p = common::arg_parser(@_);
		$logger->trace(Dumper($p));
		
		# move to template level
		my $nodeTemplate = $p->{ template }->{ associationDescriptor };
		# spawn a copy of the datastructure to be filled
		my %hash = %{$nodeTemplate};    
		my $container = \%hash;

		my $rawQuery;
                my @answerSet;
                if (defined($p->{ name })) {
		     $rawQuery = "query find Association $p->{ name }";
                     @answerSet = $p->{ DB }->fetch (-query => $rawQuery);
		} else {
		    $rawQuery = "query find Association $p->{ molA }__$p->{ molB }";
		     @answerSet = $p->{ DB }->fetch (-query => $rawQuery);
                     if (@answerSet == 0) {
		         $rawQuery = "query find Association $p->{ molB }__$p->{ molA }";
		         @answerSet = $p->{ DB }->fetch (-query => $rawQuery);
		     }		
		     if (@answerSet == 0) {
		         $logger->error("Empty matrixdb association Set for $p->{ molB } -- $p->{ molA }");
		         return;
		     }		
		     if (@answerSet > 1) {
		         $logger->warn ("more than one association found for following couple -> $p->{ molB } -- $p->{ molA }");
		     }
		}
		my $aceObject = shift (@answerSet);
		$container->{ name } = $aceObject->name;
		$logger->trace("Association sub node filling with " . Dumper($nodeTemplate));
		foreach my $key (keys (%{$nodeTemplate})) {
		    ($key eq "name") && next;
		    ($key eq "knowledge") && next; # set below in the experiment statement
		
		    if ($nodeTemplate->{ $key } eq "dummy") {
			
			my ($val) = $aceObject->get($key);
			if (!defined $val) {			    
			    $val = "N/A"; 
			} else {			    
			}
			$container->{ $key } = $val;
			next;
		    } 		   
		    if ($nodeTemplate->{ $key } =~ /^listType_(.+)$/) {		
			my $dataType = $1;
			$container->{ $key } = [];
			if ($dataType eq "experimentDescriptor") {		
			    # real experiment array
			    my @subGenuine = $aceObject->follow('Experiment');
			    # experiment array supporting inferrence
			    my @subInferrence;
			    # association from which current association might be inferred
			    my @assocInferring = $aceObject->follow('InferredFrom');
			    if (@assocInferring > 0 && @subGenuine > 0) {
				$container->{ knowledge } = "Mixed";
			    } else {
				$container->{ knowledge } = @assocInferring > 0 ? "Inferred" : "Genuine";
			    }

			    foreach my $genuineAssocObj (@assocInferring) {
				my @eTmp = $genuineAssocObj->follow('Experiment');
				foreach my $eAceObjectInferring (@eTmp) {
				    push @subInferrence, $eAceObjectInferring;
				}
			    }

			    $logger->trace("current Association experiment array sizes:\n".
					   "realExp =  " . scalar(@subGenuine). "\n" .
					   "inferredFromExp =  " . scalar(@subInferrence) . "\n"
				);
			    foreach my $eAceObject (@subGenuine) { #   foreach my $eAceObject (@subGenuine, @subInferrence) {
				my $subContainer = 
				    $p->{ mapper }->{ experimentDescriptor }($p->{ mapper },
								      $p->{ template }, 
								      $p->{ db }, $eAceObject, "actual");
				if (!defined ($subContainer)) {
				    #warn "failed to map experiment " . $eAceObject->name;
				    next;
				}
				push @{$container->{ $key }}, $subContainer;				
			    }
			    foreach my $eAceObject (@subInferrence) {
				my $subContainer = 
				    $p->{ mapper }->{ experimentDescriptor }($p->{ mapper },
								      $p->{ template }, 
								      $p->{ db }, $eAceObject, "inferrence");
				if (!defined ($subContainer)) {
				    #warn "failed to map experiment " . $eAceObject->name;
				    next;
				}
				push @{$container->{ $key }}, $subContainer;				
			    }

			}
		    }		    
		}
		
		$logger->trace("About to return following association container:\n" . Dumper($container));
		return $container;		
	    },
	    experimentDescriptor => sub {
$logger->trace("ANONY_PASS");
		my $mapper = shift;
		my $template = shift;
		my $db = shift;
		my $eAceObject = shift;
		my $knowledgeSupport = shift;

		my $nodeTemplate = $template->{ experimentDescriptor };
		$logger->trace("Experiment sub node filling with " . Dumper($nodeTemplate));
# spawn a copy of the datastructure to be filled
		my %hash = %{$nodeTemplate};    
		my $container = \%hash;
		
		$container->{ name } = $eAceObject->name;
		$container->{ sourceDatabase } = "matrixdb";
		$container->{ type } = "experiment";
		$container->{ knowledgeSupport } = $knowledgeSupport;
                $container->{ Interaction_Detection_Method } = "someDetectionMethodXXX";
		foreach my $key (keys (%{$nodeTemplate})) {
		    ($key eq "name" || $key eq "sourceDatabase" || $key eq "knowledgeSupport") && next;
                    #|| $key eq "Interaction_Detection_Method") && next;
		    my $pos = 1;
		           $logger->trace("CURR_KEY IS  " . $key);
		    if ($nodeTemplate->{ $key } =~ /^dummy/) {
			my $val;
			if ($nodeTemplate->{ $key } =~ /([\d]+)$/) {
			    $pos += $1;
			}
			if ($nodeTemplate->{ $key } eq "dummy") {
			    $val = getAceScalar(aceObject => $eAceObject, key => $key, pos => $pos);
			}
			elsif ($nodeTemplate->{ $key } =~ /dummyCV/) {
	 		       $logger->trace("WESHH " . $key);
                               ($val) = $eAceObject->get ($key, $pos);
			      #undef $val; ##DBG purpose
                               if (defined ($val)) {
                                $logger->trace("Attempting to run CV request for $key");
                                my $cvTerm = localSocket::runCvRequest (with => $CV_SOCKET, from => 'matrixDB',
							   askFor => 'id', selectors => { name => $val }
				    );		
		                $logger->trace("Attempting to run CV request OK ");
				$val = $val->name . "[$cvTerm]";
			    } else {
                                $logger->trace("$key search within $eAceObject returned undefine");
                            }			    
			}
			elsif ($nodeTemplate->{ $key } eq "dummyList") {
			    my @row = $eAceObject->row ($key);
			    $val = join (' ', @row);
			}

			$container->{ $key } = defined($val) ? $val : 'N/A';
			next;
			
		    } elsif ($nodeTemplate->{ $key } =~ /^(^_+)Descriptor$/) {
			if ($1 eq "kinetics") {
			    $container->{ $key } = $mapper->{ kineticsDescriptor }($mapper, $template, $db,
										      $eAceObject);
			}	
			## other singleton of constructed type to insert here

			# list of type
		    } elsif ($nodeTemplate->{ $key } =~ /^listType_(.+)$/) {	

			my $dataType = $1;
			$logger->trace("experimentMapper, following $dataType list");
			$container->{ $key } = [];
			if ($dataType eq "publicationDescriptor") {
$logger->info("publicationDescriptor in");
			    my @pubAceObject = $eAceObject->follow('PMID');
                            $logger->info(Dumper(@pubAceObject));
			    $container->{ $key } = $mapper->{ publicationDescriptor }($mapper, $template, $db,
										      $pubAceObject[0]);
$logger->info("publicationDescriptor out");
			} elsif ($dataType eq "partnerDescriptor") {
$logger->info("partnerDescriptor in");
			    $logger->info(Dumper($eAceObject));
                            my $nAceObject = $eAceObject->at('Partner.BioMolecule');
			    my @partnerTags = $nAceObject->tags();
			    $logger->trace("calling partner mapper for " . Dumper(@partnerTags));
			    foreach my $partnerName (@partnerTags) {
				my $pAceObject = $nAceObject->at($partnerName);
				(defined ($pAceObject)) || 
				    die " unexpected null object in acedb at " .
				    $eAceObject->name . " -->  $partnerName\n";
				
				my $subContainer = 
				    $mapper->{ partnerDescriptor }($mapper, $template, $db,
								   $pAceObject);
				if (!defined ($subContainer)) {
				    #warn $container->{ name } . 
				#	" , failed to map partner \"" . $partnerName ."\"";
				    next;
				}
				push @{$container->{ $key }}, $subContainer;
			    }			   
			$logger->info("partnerDescriptor out");
                        }
			## other list of constructed type to insert here
		    }
		}
		$logger->trace("About to return following Experiment container:\n" . Dumper($container));
		
		return $container;
	    },
	    kineticsDescriptor => sub {
$logger->trace("ANONY_PASS KINE");
		my $mapper = shift;
		my $template = shift;
		my $db = shift;
		my $eAceObject = shift;
		# spawn a copy of the datastructure to be filled
		my $nodeTemplate = $template->{ kineticsDescriptor };
		my %hash = %{$nodeTemplate};    
		my $container = \%hash;
		foreach my $key (keys (%{$nodeTemplate})) {
		    	my $val = getAceScalar(aceObject => $eAceObject, key => $key, pos => 1);
			$container->{ $key } = defined($val) ? $val : 'N/A';
		}
		$logger->trace("kinetic descriptor content:\n".Dumper($container));
		return $container;
	    },
	    publicationDescriptor => sub {
$logger->trace("ANONY_PASS PUBLI");
		my $mapper = shift;
		my $template = shift;
		my $db = shift;
		my $pubAceObject = shift;
		# spawn a copy of the datastructure to be filled
		my $nodeTemplate = $template->{ publicationDescriptor };
		my %hash = %{$nodeTemplate};    
		my $container = \%hash;
		$logger->trace("supposed PMID ace object content\n". $pubAceObject->asAce);
		foreach my $key (keys (%{$nodeTemplate})) {
		    if ($key eq "pmid") {
			$container->{ $key } = $pubAceObject->name;
			next;
		    }
		    if ($key eq "imex") {
			my $val = getAceScalar(aceObject => $pubAceObject, key => 'IMEx_ID', pos => 1);
			$container->{ $key } = defined($val) ? $val : 'N/A';
		    }
		}
		$logger->trace("publication Data container " . Dumper($container));
		
		return [$container];
	    },
	    partnerDescriptor => sub {
$logger->trace("ANONY_PASS");
		my $mapper = shift;
		my $template = shift;
		my $db = shift;
		my $pAceObject = shift;
		$logger->trace("partnerDescriptor crawler");
		my $nodeTemplate = $template->{ partnerDescriptor };
		# spawn a copy of the datastructure to be filled
		my %hash = %{$nodeTemplate};    
		my $container = \%hash;
		
		$container->{ name } = $pAceObject->name;
		$container->{ type } = "partner";
		#warn "current partner details " . $container->{ name };
		
		foreach my $key (keys (%{$nodeTemplate})) {
		    ($key eq "name") && next;		    
		    if ($nodeTemplate->{ $key } eq "dummy") {
			my $val = getAceScalar(aceObject => $pAceObject, key => $key, pos => 1);
#			my ($val) = $pAceObject->get ($key);
			if (!defined $val) {
			    #warn "no \"$key\" in " . $pAceObject->name;
			    $val = "N/A"; 
			} else {
			    #warn $pAceObject->name . " $key ok --> $val";
			}
			$container->{ $key } = $val;
			next;
		    } else {
#			warn "------>$nodeTemplate->{ $key }\n";			
		    }
		    
		    if (common::isHashRef($nodeTemplate->{ $key })) {	
			#warn "trying to fill hashtype attribute, \"$key\" hooked subcontainer";
			my %subHash = %{$container->{ $key }};
			my $subContainer = \%subHash;
			my $subNodeTemplate = $nodeTemplate->{ $key };			
			foreach my $subKey (keys(%{$subNodeTemplate})) {	
#			    warn "\t-->$subNodeTemplate->{ $subKey }";
			    if ($subNodeTemplate->{ $subKey } =~ /^listType_(.+)$/){
				my $dataType = $1;
				$subContainer->{ $subKey } = [];
				$subContainer->{ $subKey } = $mapper->{ $dataType }($mapper,
										    $template,
										    $pAceObject);
			    } 
			}
			$container->{ $key } = $subContainer;
		    }			    
		}

		$logger->trace("partnerDescriptor mapper returns " . Dumper($container));
		return $container;    
	    },
	    # returns a reference list of such elements
	    knownExperimentalFeatureDescriptor => sub {
$logger->trace("ANONY_PASS");
		my $mapper = shift;
		my $template = shift;
		my $pAceObject = shift;
		#warn "knownExperimentalFeatureDescriptor crawler";
		
#		open xLOG, ">>/tmp/xdbg.log";

		my @containerList = ();
		# move to template level
		my $nodeTemplate = $template->{ knownExperimentalFeatureDescriptor };
		# spawn a copy of the datastructure to be filled
		my @t_tags = $pAceObject->tags();
	
		my $aceObject = $pAceObject->at('Feature');
		if (!defined ($aceObject)) {
		    #warn "No Experimental Feature";
		    return [];
		} else {
		  
		    $aceObject = $aceObject->right(1);
		    my $cnt = 0;
#		    print xLOG "survey:\n" . $aceObject->asString ();
		    while (defined (my $pAceObject = $aceObject->down($cnt))){
			$pAceObject = $pAceObject->right(2);
			if ($pAceObject->{ name } eq "Known_Experimental_Feature") {
#			    print xLOG "inner:\n" . $pAceObject->asString ();
			  			   
			    my %hash = %{$nodeTemplate};    
			    my $container = \%hash;
			    $container->{ type } = "knownExperimentalFeature";
			    foreach my $key (keys (%{$nodeTemplate})) {
				if ($nodeTemplate->{ $key } =~ /^dummy/) {
				    my $val = getAceScalar(aceObject => $pAceObject, key => $key, pos => 1);
			            undef $val; ##DBG purpose
				    if (!defined $val) {
				#	warn "no \"$key\" in " . $pAceObject->name;
					$val = "N/A"; 
				    } else {
					if ($nodeTemplate->{ $key }  =~ /^dummyCV/) {
$logger->trace("Attempting to run CV request -->$val");
					    my $cvTerm = localSocket::runCvRequest (with => $CV_SOCKET, from => 'matrixDB',
								       askFor => 'id', selectors => { name => $val }
						);
$logger->trace("Attempting to run CV request OK ");
					    $val .= "[$cvTerm]";
					}					 
				#	warn $pAceObject->name . " $key ok --> $val";
				    }
				    $container->{ $key } = $val;
				    next;
				} 
				elsif ($nodeTemplate->{ $key } =~ /^listType_(.+)$/) {				  
				    my $dataType = $1;
#				    print xLOG "-->i have some list data type ($dataType)\n";
				    $container->{ $key } = [];
				    $container->{ $key } = $mapper->{ $dataType }($mapper,
										  $template,
										  $pAceObject);
				}
			    }			    
			    push @containerList, $container;
			}
			$cnt++;
		    }
		  
		}
	
		return \@containerList;
	    },
	    # returns a list of such datatype
	    rangeData => sub {
$logger->trace("ANONY_PASS");
		my $mapper = shift;
		my $template = shift;
		my $aceObject = shift;		
		
		my @rangeDataList = ();
		my $nodeTemplate = $template->{ rangeData };
#		open LOG, ">>/tmp/crawler_range.log" or die $!;
#		print LOG "survey:\n". $aceObject->asString() . "\n";
		$aceObject = $aceObject->right();
		my $pAceObject = $aceObject->at('Range');		
		if (defined ($pAceObject)) {
#		print LOG "inner:\n". $pAceObject->asString() . "\n";
		
#		    my @rangeTags = $pAceObject
		    $pAceObject = $pAceObject->right();
		    my $cnt = 0;
		    while (defined (my $pAceObject = $pAceObject->down($cnt))){
			my %hash = %{$nodeTemplate};    
			my $container = \%hash;
			$container->{ start } = "N/A";
			$container->{ stop } = "N/A";			
			$container->{ isLinked } = "N/A";		
#			print LOG "range $cnt " . $pAceObject->asString() . "\n";

			my @tags = $pAceObject->tags();
#			print LOG "\t\t-->@tags\n\n";
			if (common::listExist(\@tags, 'Position_start')) {
			   my $pStart = $pAceObject->get('Position_start', 1);
			   # hotfix text ought to be strict
			   if (!defined($pStart) ){ $cnt++;next;}
			   $container->{ start } = $pStart->name;			   			   
			}
			elsif (common::listExist(\@tags, 'Status_start')) {
			    my $sStart = $pAceObject->get('Status_start', 1);
			    if ($sStart->name =~ /_terminal_position/) {
				$container->{ start } = $sStart->name;
			    } 
			}
			if (common::listExist(\@tags, 'Position_end')) {
			    my $pStop = $pAceObject->get('Position_end', 1);
			    # hotfix text ought to be strict
			    if (!defined($pStop) ){ $cnt++;next;}			    
			    $container->{ stop } = $pStop->{ name };
			}
			elsif (common::listExist(\@tags, 'Status_end')) {
			    my $sStop = $pAceObject->get('Status_end', 1);			  
			    if ($sStop->name  =~ /_terminal_position/) {
				$container->{ stop } = $sStop->name;
			    } 
			}
			if (common::listExist(\@tags, 'isLinked')) {
			    my $isLinked = $pAceObject->get('isLinked', 1);
			    # hotfix text ought to be strict
			    if (!defined($isLinked) ){ $cnt++;next;}
			    $container->{ isLinked } = $isLinked->name;
			}

#			print LOG "adding rangeDatacontainer\n" . Dumper($container);
			push @rangeDataList, $container;
			$cnt++;
		    }		    
		}
#		close LOG;

		return \@rangeDataList;
	    },
	    # returns a reference list of such elements
	    bindingSiteDataDescriptor => sub {
		$logger->trace("ANONY_PASS");
		my $mapper = shift;
		my $template = shift;
		my $pAceObject = shift;
#		warn "bindingSiteDataDescriptor crawler";
		
#		open yLOG, ">>/tmp/ydbg.log";

		my @containerList = ();
		# move to template level
		my $nodeTemplate = $template->{ bindingSiteDataDescriptor };
		# spawn a copy of the datastructure to be filled
		my @t_tags = $pAceObject->tags();
	
		my $aceObject = $pAceObject->at('Feature');
		if (!defined ($aceObject)) {
		    #warn "No Experimental Feature";
		    return [];
		} else {
#		    print yLOG "survey:\n" . $aceObject->asString ();
		    
		    $aceObject = $aceObject->right(1);
		    my $cnt = 0;
	
		    while (defined (my $pAceObject = $aceObject->down($cnt))){
			$pAceObject = $pAceObject->right(2);
			if ($pAceObject->{ name } eq "Binding_Site") {
#			    print yLOG "inner:\n" . $pAceObject->asString ();
			  			   
			    my %hash = %{$nodeTemplate};    
			    my $container = \%hash;
			    $container->{ type } = "bindingSiteData"; 
			    foreach my $key (keys (%{$nodeTemplate})) {
				if ($nodeTemplate->{ $key } =~ /^dummy/) {
				    my $val = getAceScalar(aceObject => $pAceObject, key => $key, pos => 1);
			      undef $val; ##DBG purpose
				    if (!defined $val) {
#					warn "no \"$key\" in " . $pAceObject->name;
					$val = "N/A"; 
				    } else {
					if ($nodeTemplate->{ $key }  =~ /^dummyCV/) {
$logger->trace("Attempting to run CV request");
					    my $cvTerm = localSocket::runCvRequest (with => $CV_SOCKET, from => 'matrixDB',
								       askFor => 'id', selectors => { name => $val }
						);
$logger->trace("Attempting to run CV request OK");
					    $val .= "[$cvTerm]";
					}					 
	#				warn $pAceObject->name . " $key ok --> $val";
				    }
				    $container->{ $key } = $val;
				    next;
				} 
				elsif ($nodeTemplate->{ $key } =~ /^listType_(.+)$/) {				  
				    my $dataType = $1;
#				    print yLOG "-->i have some list data type ($dataType)\n";
				    $container->{ $key } = [];
				    $container->{ $key } = $mapper->{ $dataType }($mapper,
										  $template,
										  $pAceObject);
				}
			    }			    
			    push @containerList, $container;
			}
			$cnt++;
		    }
		  
		}
	
		return \@containerList;
	    },
	    ptmDescriptor => sub {
$logger->trace("ANONY_PASS");
		my $mapper = shift;
		my $template = shift;
		my $pAceObject = shift;
		#warn "ptmModificationDescriptor crawler";
		
		my @containerList = ();
		# move to template level
		my $nodeTemplate = $template->{ ptmDescriptor };
		# spawn a copy of the datastructure to be filled
		my @t_tags = $pAceObject->tags();
	
		my $aceObject = $pAceObject->at('Feature');
		if (!defined ($aceObject)) {
#		    warn "No Experimental Feature";
		    return [];
		} else {
		    $aceObject = $aceObject->right(1);
		    my $cnt = 0;
	
		    while (defined (my $pAceObject = $aceObject->down($cnt))){
			$pAceObject = $pAceObject->right(2);
			if ($pAceObject->{ name } eq "Post_Translation_Modification") {
#			    print "inner:\n" . $pAceObject->asString ();
			    my %hash = %{$nodeTemplate};    
			    my $container = \%hash;
			    $container->{ type } = "ptm";
			    foreach my $key (keys (%{$nodeTemplate})) {
				if ($nodeTemplate->{ $key } =~ /^dummy/) {
				    my $val = getAceScalar(aceObject => $pAceObject, key => $key, pos => 1);
			      undef $val; ##DBG purpose
				    if (!defined $val) {
				#	warn "no \"$key\" in " . $pAceObject->name;
					$val = "N/A"; 
				    } else {
					if ($nodeTemplate->{ $key }  =~ /^dummyCV/) {
$logger->trace("Attempting to run CV request");
					    my $cvTerm = localSocket::runCvRequest (with => $CV_SOCKET, from => 'matrixDB',
								       askFor => 'id', selectors => { name => $val }
						);
$logger->trace("Attempting to run CV request OK");
					    $val .= "[$cvTerm]";
					}					 
				#	warn $pAceObject->name . " $key ok --> $val";
				    }
				    $container->{ $key } = $val;
				    next;
				} 
				elsif ($nodeTemplate->{ $key } =~ /^listType_(.+)$/) {				  
				    my $dataType = $1;
#				    print "-->i have some list data type ($dataType)\n";
				    $container->{ $key } = [];
				    $container->{ $key } = $mapper->{ $dataType }($mapper,
										  $template,
										  $pAceObject);
				}
			    }			    
			    push @containerList, $container;
			}
			$cnt++;
		    }
		  
		}

		return \@containerList;	
	    },
	    pointMutationDescriptor => sub {
$logger->trace("ANONY_PASS");
		my $mapper = shift;
		my $template = shift;
		my $pAceObject = shift;
	#	warn "pointMutationDescriptor crawler";
		
		my @containerList = ();
		# move to template level
		my $nodeTemplate = $template->{ pointMutationDescriptor };
		# spawn a copy of the datastructure to be filled
		my @t_tags = $pAceObject->tags();
	
		my $aceObject = $pAceObject->at('Feature');
		if (!defined ($aceObject)) {
		    #warn "No Experimental Feature";
		    return [];
		} else {
#		    print  "survey:\n" . $aceObject->asString ();
		    
		    $aceObject = $aceObject->right(1);
		    my $cnt = 0;
	
		    while (defined (my $pAceObject = $aceObject->down($cnt))){
			$pAceObject = $pAceObject->right(2);
			if ($pAceObject->{ name } eq "PointMutation") {
#			    print uLOG "inner:\n" . $pAceObject->asString ();
			  			   
			    my %hash = %{$nodeTemplate};    
			    my $container = \%hash;
			    $container->{ type } = "pointMutation";
			    foreach my $key (keys (%{$nodeTemplate})) {
				if ($nodeTemplate->{ $key } =~ /^dummy/) {
				    my $val = getAceScalar(aceObject => $pAceObject, key => $key, pos => 1);
			      undef $val; ##DBG purpose
				    if (!defined $val) {
#					warn "no \"$key\" in " . $pAceObject->name;
					$val = "N/A"; 
				    } else {
					if ($nodeTemplate->{ $key }  =~ /^dummyCV/) {
$logger->trace("Attempting to run CV request");
					    my $cvTerm = localSocket::runCvRequest (with => $CV_SOCKET, from => 'matrixDB',
								       askFor => 'id', selectors => { name => $val }
						);
$logger->trace("Attempting to run CV request OK");
					    $val .= "[$cvTerm]";
					}					 
#					warn $pAceObject->name . " $key ok --> $val";
				    }
				    $container->{ $key } = $val;
				    next;
				} 
				elsif ($nodeTemplate->{ $key } =~ /^listType_(.+)$/) {				  
				    my $dataType = $1;
#				    print uLOG "-->i have some list data type ($dataType)\n";
				    $container->{ $key } = [];
				    $container->{ $key } = $mapper->{ $dataType }($mapper,
										  $template,
										  $pAceObject);
				}
			    }			    
			    push @containerList, $container;
			}
			$cnt++;
		    }
		  
		}
	
	
#		print uLOG " --> " .Dumper(@containerList);
#		close uLOG;
		
		return \@containerList;	
	    }

	};      
    }
    $logger->logdie("Summoning mapper of unknown format \"$template->{ version }\"");
}

1;



