xquery version "1.0-ml";

module namespace res = "http://marklogic.com/rest-api/resource/data-links";

import module namespace json = "http://marklogic.com/xdmp/json" at "/MarkLogic/json/json.xqy";
import module namespace sem = "http://marklogic.com/semantics" at "/MarkLogic/semantics.xqy";


declare function res:get(
  $context as map:map,
  $params  as map:map
) as document-node()*
{
  let $subject := map:get($params, "subject")
  return build-graph($subject, map:get($params, "expand") = "true")
};



declare function build-graph(
  $subjects,
  $is-expand as xs:boolean
  )
{
  let $nodes := json:array()
  let $edges := json:array()
  let $nodes-map := map:map()

  let $subject-labels := <x>{cts:triples($subjects ! sem:iri(.), sem:iri("http://www.w3.org/2000/01/rdf-schema#label"))}</x>/*
  let $subject-types := get-types($subjects)

  let $_ :=
  for $subject in $subjects

  let $params := map:new((
    map:entry("subject", sem:iri($subject))
  ))
  let $q := fn:concat(
    "
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    SELECT (COALESCE(?predicateLabel, ?predicateUri) AS ?predicate)
           ?predicateUri
           ?object
           ?label
    WHERE {
      ?subject ?predicateUri ?object . ",
    sparql-filter(),
    "
      OPTIONAL {
        ?predicateUri rdfs:label ?predicateLabel .
      }
      OPTIONAL {
        ?object rdfs:label ?label .
      }
    }
    LIMIT 100
    ")

  let $results := sem:sparql($q, $params)

  (: Do separate query for triples where our uri is the object. :)
  let $params := map:new((
    map:entry("object", sem:iri($subject))
  ))
  let $q := "
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    SELECT ?subject
           (COALESCE(?predicateLabel, ?predicateUri) AS ?predicate)
           ?predicateUri
           ?label
    WHERE {
      ?subject ?predicateUri ?object .
      OPTIONAL {
        ?subject rdfs:label ?label .
      }
      OPTIONAL {
        ?predicateUri rdfs:label ?predicateLabel .
      }
    }
    LIMIT 100
  "

  let $results-obj := sem:sparql($q, $params)

  return
        (
          if ($is-expand) then ()
          else
            let $node := json:object()
            (:let $label := ($subject-labels[sem:subject = $subject]/sem:object/string(), $subject)[1]:)
            let $label := get-label($subject)
            let $type := retrieve-type($subject-types, $subject)
            return (
              map:put($node, "label", $label),
              map:put($node, "id", $subject),
              map:put($node, "group", $type),
              map:put($node, "edgeCount", get-edge-count($subject)),
              map:put($nodes-map, $subject, $node)
            ),

          for $result in $results
          let $object := map:get($result, "object")
          let $object-types := get-types($object)
          let $object-type := retrieve-type($object-types, $object)
          let $node := json:object()
          let $label := get-label($object)
          return (
            (:map:put($node, "label", (map:get($result, "label"),$object)[1]),:)
            map:put($node, "label", $label),
            map:put($node, "id", $object),
            map:put($node, "group", $object-type),
            map:put($node, "edgeCount", get-edge-count($object)),
            map:put($nodes-map, $object, $node),

            let $edge := json:object()
            where $subject != $object cast as xs:string
            return (
              map:put($edge, "id", "edge-" || $subject || "-" || $object),
              map:put($edge, "from", $subject),
              map:put($edge, "to", $object),
              let $predicate := map:get($result, "predicate")
              let $predicate := (fn:tokenize($predicate, "#")[last()], $predicate)[1] (: use the string after #, if any :)
              let $predicate := xdmp:url-decode($predicate)
              let $predicate-uri := map:get($result, "predicateUri")
              let $predicate-label := get-label($predicate)
              return (map:put($edge, "label", $predicate-label),
                map:put($edge, "type", $predicate-uri),
                json:array-push($edges, $edge)
              )
            )
          ),

          for $result in $results-obj
          let $subj := map:get($result, "subject")
          let $subj-types := get-types($subj)
          let $subj-type := retrieve-type($subj-types, $subj)
          let $node := json:object()
          let $label := get-label($subj)
          return (
            (:map:put($node, "label", (map:get($result, "label"),$subj)[1]),:)
            map:put($node, "label", $label),
            map:put($node, "id", $subj),
            map:put($node, "group", $subj-type),
            map:put($node, "edgeCount", get-edge-count($subj)),
            map:put($nodes-map, $subj, $node),

            let $edge := json:object()
            where $subject != $subj cast as xs:string
            return (
              map:put($edge, "id", "edge-" || $subj || "-" || $subject),
              map:put($edge, "from", $subj),
              map:put($edge, "to", $subject),
              let $predicate := map:get($result, "predicate")
              let $predicate := (fn:tokenize($predicate, "#")[last()], $predicate)[1] (: use the string after #, if any :)
              let $predicate := xdmp:url-decode($predicate)
              let $predicate-uri := map:get($result, "predicateUri")
              let $predicate-label := get-label($predicate)
              return (map:put($edge, "label", $predicate-label),
                map:put($edge, "type", $predicate-uri),
                json:array-push($edges, $edge)
              )
            )
          )
        )

  (: Move node data from map to array. :)
  let $_ :=
    for $key in map:keys($nodes-map)
    return
      json:array-push($nodes, map:get($nodes-map, $key))

  return
    document {
      xdmp:to-json(
        let $data-object := json:object()
        let $_ := map:put($data-object, "nodes", $nodes)
        let $_ := map:put($data-object, "edges", $edges)
        return $data-object
      )
    }

};

declare private function get-types($subjects as xs:string*) as node()*
{
  <x>{cts:triples($subjects ! sem:iri(.), sem:iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"))}</x>/*
};

declare private function retrieve-type(
  $types as node()*,
  $uri as xs:string
) as xs:string?
{
  ($types[sem:subject = $uri]/sem:object/string(), "unknown")[1]
};

declare private function get-label($subject as xs:string) as xs:string
{
  let $tokens := tokenize($subject, "/")
  return
    if (count($tokens) = 1) then $subject
    else $tokens[last()]
};

declare private function sparql-filter() as xs:string
{
  " FILTER(?predicateUri != rdfs:label &amp;&amp; ?predicateUri != rdf:type) "
};

declare private function get-edge-count($subject) as xs:int
{

  let $params := map:new( map:entry("subject", sem:iri($subject)) )
  let $q := fn:concat(
    "
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    SELECT (COUNT(DISTINCT ?object) AS ?count)
    WHERE {
      {
        ?subject ?predicateUri ?object . ",
    sparql-filter(),
    "
      }
      UNION
      {
        ?object ?predicate ?subject
      }
    }
    LIMIT 200
    ")

  let $count :=
    if (sem:isIRI($subject)) then
      map:get(sem:sparql($q, $params), "count")
    else
      0

  return $count
};
