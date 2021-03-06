function initStatView (options){
	
	if (! options.hasOwnProperty('statDiv')) {
		alert("Cant start component w/out targetDiv");
		return;
	}
	
	var elem = $(options.statDiv)[0]; 
	
	if (!elem) {
		alert("Cant get targetDiv element in document");
		return;
	}
	return{
		targetDomElem : elem,
		start : function(){
			var self = this;
			var jqxhr = $.ajax({
	        			   type: 'GET',
	        			   dataType: 'json',
	        			   data: { },
	        			   url: 'cgi-bin/current/statistic',
	        		       })
	        	.success (function (data) {
	     self._statDraw(data);
	    			      
	      			  })
			.error(function (xhr, status, error) {
				   var err = eval("(" + xhr.responseText + ")");
				   alert(err.Message);
			});
		},
		_statDraw : function(data){
				console.dir(data)
				var scaffold = '<div class = "row-fluid"><div class = "span6 firstPart"></div><div class = "span6 secondPart"></div></div>';
			 	var self = this;
			    var tableInteractor ='<table bgcolor="white" class="table table-bordered" >'+
                      			 '<thead><tr><th>Associations</th><th>Protein</th><th>Multimer</th><th>PFrag*</th><th>GAG**</th>'+
                      			 '</tr></thead><tbody>'+
                      			 '<tr><th>GAG**</th><td>' + data.associations.glycosaminoglycanProtein + '</td>'+
	                      			 '<td>' + data.associations.glycosaminoglycanMultimer + '</td>'+
	                      			 '<td>' + data.associations.fragmentGlycosaminoglycan + '</td>'+
	                      			 '<td>' + data.associations.GlycosaminoglycanGlycosaminoglycan + '</td></tr>'+
                      			 '<tr><th>PFrag*</th><td>' + data.associations.fragmentProtein + '</td>'+
                      			 	'<td>' + data.associations.fragmentMultimer + '</td>'+
                      			 	'<td>' + data.associations.Protein_FragmentProtein_Fragment + '</td><td></td></tr>'+
                      			 '<tr><th>Multimer</th><td>' + data.associations.multimerProtein + '</td>'+
                      			 	'<td>' + data.associations.MultimerMultimer + '</td><td></td><td></td></tr>'+
                      			 '<tr><th>Protein</th><td>' + data.associations.ProtProt + '</td><td></td><td></td><td></td></tr>';
			    var tableFinal = '<table bgcolor="white" class="table table-bordered" >'+
                      			 '<thead><tr><th>Molecular interaction Data</th>'+
                      			 '<th class="mdbHead"><img src = "/img/icon-mdb.png" width = "15px" ></img></th>'+
                      			 '<th class="psqHead"><img src = "/img/psicquic.png" width = "20px"></img></th></tr></thead><tbody>';
			 	tableInteractor += '</tbody></table><div><b>  *</b> : Bioactive <b>P</b>rotein <b>frag</b>ment</br><b>**</b> : <b>G</b>lycos<b>A</b>mino<b>G</b>lycan</div>';
			 	var pub = data.publications.total - data.publications.imex
				tableFinal += '<tr><td>Experimentally supported associations</td><td>' + data.interactions.matrixdb[0] + '</td><td>' + data.interactions.psicquic[0] + '</td></tr>' +
							  '<tr><td>Experiments</td><td>' + data.interactions.matrixdb[1] + '</td><td>' + data.interactions.psicquic[1] + '</td></tr>' +
							  '</tbody></table>' +'<table bgcolor="white" class="table table-bordered" style=" max-height: 250px;">'+
                      		  '<thead><tr><th>Publications</th><th>Number</th></tr></thead><tbody>' +
							  '<tr><td>MIMIx-level curated publications (including IMEx-level)</td><td>' + data.publications.total + '</td></tr>'+
							  '<tr><td>IMEx-level curated publications</td><td>' + data.publications.imex + '</td></tr>' ;
				tableFinal += '</tbody></table>';
				var date = "Real-time updates";
				$(self.targetDomElem).append( date + scaffold);
				$(self.targetDomElem).find("div.firstPart").append(tableFinal);
				$(self.targetDomElem).find("div.secondPart").append(tableInteractor);
				$("th.mdbHead").tooltip({title : "MatrixDB CORE dataset", container : 'body'});
				$("th.psqHead").tooltip({title : "Psicquic extended dataset (including MatrixDB CORE)", container : 'body'});
				
		},
		_dataPie : function(data){
			var w = 200,                        //width
			    h = 400,                            //height
			    r = Math.min(w, h) / 2,                            //radius
			    color = d3.scale.category20c();
			    var vis = d3.select("body")
			        .append("svg:svg")              //create the SVG element inside the <body>
			        .data([data])                   //associate our data with the document
			            .attr("width", w)           //set the width and height of our visualization (these will be attributes of the <svg> tag
			            .attr("height", h)
			        .append("svg:g")                //make a group to hold our pie chart
			            .attr("transform", "translate(" + r + "," + r + ")")    //move the center of the pie chart from 0, 0 to radius, radius
			 
			    var arc = d3.svg.arc()              //this will create <path> elements for us using arc data
			        .outerRadius(r);
			 
			    var pie = d3.layout.pie()           //this will create arc data for us given a list of values
			        .value(function(d) { return d.value; });    //we must tell it out to access the value of each element in our data array
			 
			    var arcs = vis.selectAll("g.slice")     //this selects all <g> elements with class slice (there aren't any yet)
			        .data(pie)                          //associate the generated pie data (an array of arcs, each having startAngle, endAngle and value properties) 
			        .enter()                            //this will create <g> elements for every "extra" data element that should be associated with a selection. The result is creating a <g> for every object in the data array
			            .append("svg:g")                //create a group to hold each slice (we will have a <path> and a <text> element associated with each slice)
			                .attr("class", "slice");    //allow us to style things in the slices (like text)
			 
			        arcs.append("svg:path")
			                .attr("fill", function(d, i) { return color(i); } ) //set the color for each slice to be chosen from the color function defined above
			                .attr("d", arc);                                    //this creates the actual SVG path using the associated data (pie) with the arc drawing function
			 
			        /*arcs.append("svg:text")                                     //add a label to each slice
		                .attr("transform", function(d) {                    //set the label's origin to the center of the arc
		                //we have to make sure to set these before calling arc.centroid
		                d.innerRadius = r;
		                d.outerRadius = r;
		                return "translate(" + arc.centroid(d) + ")";        //this gives us a pair of coordinates like [50, 50]
		            })
			            .attr("text-anchor", "middle")                          //center the text on it's origin
			            .text(function(d, i) { return pieDataAsso[i].label; }); */
		}
		
	}
}
