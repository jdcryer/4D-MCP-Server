// MCP_Config — read / merge / validate / write the deployment config document,
// 4D-mcp-config.pref. This is the *editing* half of the config story; the
// serving half is MCP_Handler.getConfig(), which flattens {comment, value} to
// {value} and fails closed. Nothing here is ever called on the request path.
//
// The document format is the file's contract:  { KEY: {comment, value}, ... }
// with keys starting "_" reserved for documentation. Editing must preserve
// BOTH halves — an admin who improved a comment, or a newer build that added a
// key this UI doesn't know about, must not lose it on save. So every function
// here works on the RAW document (comments intact) and only ever assigns to
// .value.
//
// Where the file lives: the live config is the HOST's Project/Sources copy; the
// component's Resources copy is only the shipping template that getConfig()
// clones on first read. Both paths come from MCP_Handler so the editor and the
// loader can never disagree about which file is authoritative.

shared singleton Class constructor()
	
	// =============================================================================
	//  File locations
	// =============================================================================
	
Function hostFile() : 4D.File
	return cs.MCP_Handler.me._configFile()
	
Function componentFile() : 4D.File
	return cs.MCP_Handler.me._defaultConfigFile()
	
	// fileFor: "component" = the shipping template inside the component's
	// Resources (read-only once the component is compiled into a .4dz);
	// anything else = the host's live copy.
Function fileFor($target : Text) : 4D.File
	If (This.isComponentTarget($target))
		return This.componentFile()
	End if 
	return This.hostFile()
	
Function isComponentTarget($target : Text) : Boolean
	// Compared by length + exact content: 4D's text "=" treats @ as a wildcard.
	return (Length(String($target))=9) && (Lowercase(String($target))="component")
	
	// =============================================================================
	//  Read / write
	// =============================================================================
	
	// readDoc: the raw {KEY:{comment,value}} document, or Null when the file is
	// absent, unreadable or not a JSON object. Callers decide what to do about it —
	// unlike getConfig(), this half of the system does not fail closed silently.
Function readDoc($file : 4D.File) : Object
	If ($file=Null)
		return Null
	End if 
	If (Not($file.exists))
		return Null
	End if 
	var $raw : Variant
	$raw:=Try(JSON Parse($file.getText()))
	If ($raw=Null)
		return Null
	End if 
	If (Value type($raw)#Is object)
		return Null
	End if 
	return $raw
	
Function defaultDoc() : Object
	return This.readDoc(This.componentFile())
	
	// writeDoc: pretty-printed JSON, parent folder created if needed. Returns ""
	// on success, else the error text (a compiled component's own Resources are
	// read-only, so "save to component" legitimately fails).
Function writeDoc($file : 4D.File; $doc : Object) : Text
	If ($file=Null)
		return "No file to write to."
	End if 
	If ($doc=Null)
		return "Nothing to write."
	End if 
	Try
		$file.parent.create()
		$file.setText(JSON Stringify($doc; *))
	Catch
		return This._lastErrorText()
	End try
	return ""
	
	// =============================================================================
	//  Document shape
	// =============================================================================
	
	// valueOf: the .value for a key, or $fallback when the key is absent or its
	// entry is malformed.
Function valueOf($doc : Object; $key : Text; $fallback : Variant) : Variant
	If ($doc=Null)
		return $fallback
	End if 
	var $entry : Variant
	$entry:=$doc[$key]
	If ($entry=Null)
		return $fallback
	End if 
	If (Value type($entry)#Is object)
		return $fallback
	End if 
	If ($entry.value=Null)
		return $fallback
	End if 
	return $entry.value
	
	// setValue: assign .value, keeping the existing comment. A key that isn't in
	// the document yet is created with the comment the component ships for it, so
	// a config rebuilt from a partial file still documents itself.
Function setValue($doc : Object; $key : Text; $value : Variant)
	If ($doc=Null)
		return 
	End if 
	If (Value type($doc[$key])=Is object)
		$doc[$key].value:=$value
		return 
	End if 
	var $comment : Text
	$comment:=""
	var $def : Object
	$def:=This.defaultDoc()
	If ($def#Null) && (Value type($def[$key])=Is object)
		$comment:=String($def[$key].comment)
	End if 
	$doc[$key]:=New object("comment"; $comment; "value"; $value)
	
	// flatten: the { KEY: value } view MCP_Handler.getConfig() serves, built from
	// an in-memory document. Used for validation and for the "effective settings"
	// the UI previews — it does NOT fail closed on a malformed entry (validate()
	// reports those instead); the entry is simply skipped.
Function flatten($doc : Object) : Object
	var $out : Object
	$out:=New object
	If ($doc=Null)
		return $out
	End if 
	var $key : Text
	For each ($key; $doc)
		If (Substring($key; 1; 1)="_")
			continue
		End if 
		If (Value type($doc[$key])#Is object)
			continue
		End if 
		$out[$key]:=$doc[$key].value
	End for each 
	return $out
	
	// mergeMissing: bring the document up to the component's shipping key set and
	// re-order it to match, so a file written by an older build gains the newer
	// settings (at their default values) instead of silently running without them.
	// Existing entries are carried over BY REFERENCE — edited comments survive.
	// Unknown keys are kept, after the known ones. Returns the names added.
Function mergeMissing($doc : Object) : Collection
	var $added : Collection
	$added:=New collection
	If ($doc=Null)
		return $added
	End if 
	var $def : Object
	$def:=This.defaultDoc()
	If ($def=Null)
		return $added  // no template to merge from — leave the document alone
	End if 
	
	var $out : Object
	$out:=New object
	var $key : Text
	For each ($key; $def)
		If ($doc[$key]#Null)
			$out[$key]:=$doc[$key]
		Else 
			$out[$key]:=$def[$key]
			If (Substring($key; 1; 1)#"_")
				$added.push($key)
			End if 
		End if 
	End for each 
	For each ($key; $doc)
		If ($out[$key]=Null)
			$out[$key]:=$doc[$key]
		End if 
	End for each 
	
	// Rewrite $doc in place: the form holds this reference, so replacing the
	// object would strand the UI on the old one.
	var $existing : Collection
	$existing:=OB Keys($doc)
	For each ($key; $existing)
		OB REMOVE($doc; $key)
	End for each 
	For each ($key; $out)
		$doc[$key]:=$out[$key]
	End for each 
	return $added
	
	// =============================================================================
	//  Vocabularies (the values the UI offers; the comments in the .pref are spec)
	// =============================================================================
	
Function argTypes() : Collection
	return New collection("text"; "number"; "boolean"; "object"; "collection")
	
Function logLevels() : Collection
	return New collection("off"; "error"; "info"; "debug")
	
Function tokenStores() : Collection
	return New collection("inline"; "table")
	
	// wireMaxLimit: the page-size ceiling fixed by wire contract v1. MAX_LIMIT may
	// be set lower than this, never higher.
Function wireMaxLimit() : Integer
	return 80
	
	// dataclassNames: the host datastore's dataclasses, or an empty collection when
	// there is no datastore to look at (never throws — the settings window has to
	// open even on a host with no structure).
Function dataclassNames() : Collection
	var $out : Collection
	$out:=New collection
	Try
		var $name : Text
		For each ($name; OB Keys(ds))
			$out.push($name)
		End for each 
	Catch
	End try
	return $out
	
	// =============================================================================
	//  Validation
	// =============================================================================
	// Returns a collection of { severity: "error"|"warning"; key; message }.
	// Errors block a save (they would make getConfig fail closed, or hand the
	// gates a value they can't honour); warnings are surfaced but never block —
	// "ALLOW_WRITE is on" is a deliberate choice, not a mistake.
	
Function validate($doc : Object) : Collection
	var $out : Collection
	$out:=New collection
	If ($doc=Null)
		$out.push(This._issue("error"; ""; "The config document could not be read."))
		return $out
	End if 
	
	// --- structure: every non-"_" entry must be {comment, value} -------------
	var $key : Text
	For each ($key; $doc)
		If (Substring($key; 1; 1)="_")
			continue
		End if 
		If (Value type($doc[$key])#Is object)
			$out.push(This._issue("error"; $key; \
				$key+" is not a {comment, value} entry — getConfig() refuses to load the whole file when any entry is malformed."))
		End if 
	End for each 
	
	var $c : Object
	$c:=This.flatten($doc)
	
	// --- unknown keys --------------------------------------------------------
	var $def : Object
	$def:=This.defaultDoc()
	If ($def#Null)
		For each ($key; $doc)
			If (Substring($key; 1; 1)="_")
				continue
			End if 
			If ($def[$key]=Null)
				$out.push(This._issue("warning"; $key; \
					$key+" is not a setting this build recognises. It is kept in the file, but nothing reads it."))
			End if 
		End for each 
	End if 
	
	// --- server --------------------------------------------------------------
	If (Not(Bool($c.ENABLED)))
		$out.push(This._issue("warning"; "ENABLED"; \
			"ENABLED is off — the component loads but answers every request with 403 CAP_DENIED."))
	End if 
	var $port : Real
	$port:=Num($c.HTTP_PORT)
	If (($port<0) || ($port>65535) || ($port#Int($port)))
		$out.push(This._issue("error"; "HTTP_PORT"; "HTTP_PORT must be a whole number between 0 and 65535."))
	End if 
	If (Num($c.MAX_BODY_SIZE)<0)
		$out.push(This._issue("error"; "MAX_BODY_SIZE"; "MAX_BODY_SIZE cannot be negative (0 = unlimited)."))
	End if 
	If (Not(Bool($c.REQUIRE_HTTPS)))
		$out.push(This._issue("warning"; "REQUIRE_HTTPS"; \
			"REQUIRE_HTTPS is off — tokens will cross the wire in clear text. Local development only."))
	End if 
	
	// --- verb gates ----------------------------------------------------------
	If (Bool($c.ALLOW_WRITE))
		$out.push(This._issue("warning"; "ALLOW_WRITE"; "ALLOW_WRITE is on — clients can create and update entities."))
	End if 
	If (Bool($c.ALLOW_DELETE))
		$out.push(This._issue("warning"; "ALLOW_DELETE"; "ALLOW_DELETE is on — clients can delete entities."))
	End if 
	
	// --- paging --------------------------------------------------------------
	var $maxLimit : Real
	$maxLimit:=Num($c.MAX_LIMIT)
	If ($maxLimit<1)
		$out.push(This._issue("error"; "MAX_LIMIT"; "MAX_LIMIT must be at least 1."))
	End if 
	If ($maxLimit>This.wireMaxLimit())
		$out.push(This._issue("error"; "MAX_LIMIT"; \
			"MAX_LIMIT may not exceed "+String(This.wireMaxLimit())+" — wire contract v1 fixes the ceiling."))
	End if 
	var $defLimit : Real
	$defLimit:=Num($c.DEFAULT_LIMIT)
	If ($defLimit<1)
		$out.push(This._issue("error"; "DEFAULT_LIMIT"; "DEFAULT_LIMIT must be at least 1."))
	End if 
	If ($defLimit>$maxLimit)
		$out.push(This._issue("error"; "DEFAULT_LIMIT"; "DEFAULT_LIMIT cannot be larger than MAX_LIMIT."))
	End if 
	
	// --- table exposure ------------------------------------------------------
	$out:=$out.combine(This._validateTableList($c; "WHITELIST_TABLES"))
	$out:=$out.combine(This._validateTableList($c; "BLACKLIST_TABLES"))
	If ((Value type($c.WHITELIST_TABLES)=Is collection) && ($c.WHITELIST_TABLES.length>0))
		If ((Value type($c.BLACKLIST_TABLES)=Is collection) && ($c.BLACKLIST_TABLES.length>0))
			$out.push(This._issue("warning"; "BLACKLIST_TABLES"; \
				"BLACKLIST_TABLES is ignored while WHITELIST_TABLES is non-empty."))
		End if 
		If (Bool($c.RESPECT_4D_SCHEMA))
			$out.push(This._issue("warning"; "WHITELIST_TABLES"; \
				"A non-empty WHITELIST_TABLES also overrides RESPECT_4D_SCHEMA — listed dataclasses are exposed even if the structure hides them."))
		End if 
	Else 
		If (Not(Bool($c.RESPECT_4D_SCHEMA)))
			$out.push(This._issue("warning"; "RESPECT_4D_SCHEMA"; \
				"RESPECT_4D_SCHEMA is off and no whitelist is set — every table and field in the host is exposed."))
		End if 
	End if 
	
	// --- tokens & rate -------------------------------------------------------
	var $store : Text
	$store:=String($c.TOKEN_STORE)
	If (This.tokenStores().indexOf($store)<0)
		$out.push(This._issue("error"; "TOKEN_STORE"; "TOKEN_STORE must be one of: "+This.tokenStores().join(", ")+"."))
	End if 
	If ($store="table")
		If (Length(String($c.TOKEN_TABLE))=0)
			$out.push(This._issue("error"; "TOKEN_TABLE"; "TOKEN_STORE is \"table\" but TOKEN_TABLE names no dataclass."))
		Else 
			If (Not(This._dataclassExists(String($c.TOKEN_TABLE))))
				$out.push(This._issue("warning"; "TOKEN_TABLE"; \
					"No dataclass named "+String($c.TOKEN_TABLE)+" in the host datastore."))
			End if 
		End if 
	End if 
	If (Num($c.RATE_LIMIT)<0)
		$out.push(This._issue("error"; "RATE_LIMIT"; "RATE_LIMIT cannot be negative (0 = unlimited)."))
	End if 
	
	// --- logging -------------------------------------------------------------
	If (This.logLevels().indexOf(String($c.LOG_LEVEL))<0)
		$out.push(This._issue("error"; "LOG_LEVEL"; "LOG_LEVEL must be one of: "+This.logLevels().join(", ")+"."))
	End if 
	
	// --- callable methods ----------------------------------------------------
	$out:=$out.combine(This._validateWhitelist($c))
	return $out
	
	// _validateTableList: WHITELIST_TABLES / BLACKLIST_TABLES must be a collection
	// of dataclass names. MCP_Schema fails CLOSED on a malformed list (it exposes
	// nothing at all), so a wrong type here is an error, not a warning.
Function _validateTableList($c : Object; $key : Text) : Collection
	var $out : Collection:=New collection
	var $v : Variant:=$c[$key]
	
	If ($v=Null)
		return $out
	End if 
	
	If (Value type($v)=Is text)
		If (Length(String($v))=0)
			return $out
		End if 
		$out.push(This._issue("warning"; $key; $key+" should be a list of dataclass names; treating the text value as a single-item list."))
		$v:=New collection(String($v))
	Else 
		If (Value type($v)#Is collection)
			$out.push(This._issue("error"; $key; $key+" must be a list of dataclass names — anything else exposes nothing at all."))
			return $out
		End if 
		
	End if 
	
	var $name : Variant
	For each ($name; $v)
		If (Value type($name)#Is text)
			$out.push(This._issue("error"; $key; $key+" contains an entry that is not a dataclass name."))
			continue
		End if 
		If (Length(String($name))=0)
			$out.push(This._issue("error"; $key; $key+" contains an empty name."))
			continue
		End if 
		If (Not(This._dataclassExists(String($name))))
			$out.push(This._issue("warning"; $key; \
				$key+": no dataclass named "+String($name)+" in the host datastore."))
		End if 
	End for each 
	return $out
	
	// _validateWhitelist: METHOD_WHITELIST is the highest-risk setting in the file —
	// each entry is a door into host code — so it gets the strictest check.
Function _validateWhitelist($c : Object) : Collection
	var $out : Collection
	$out:=New collection
	var $wl : Variant
	$wl:=$c.METHOD_WHITELIST
	If ($wl=Null)
		return $out
	End if 
	If (Value type($wl)#Is object)
		$out.push(This._issue("error"; "METHOD_WHITELIST"; "METHOD_WHITELIST must be an object mapping action name to spec."))
		return $out
	End if 
	
	var $names : Collection
	$names:=OB Keys($wl)
	If (Bool($c.ALLOW_CALL_METHOD))
		If ($names.length=0)
			$out.push(This._issue("warning"; "METHOD_WHITELIST"; \
				"ALLOW_CALL_METHOD is on but no actions are listed — call_method has nothing to reach."))
		Else 
			$out.push(This._issue("warning"; "METHOD_WHITELIST"; \
				String($names.length)+" host method(s) are callable by clients holding a matching token."))
		End if 
	Else 
		If ($names.length>0)
			$out.push(This._issue("warning"; "METHOD_WHITELIST"; \
				"ALLOW_CALL_METHOD is off, so these "+String($names.length)+" action(s) are ignored entirely."))
		End if 
	End if 
	
	var $types : Collection
	$types:=This.argTypes()
	var $name : Text
	For each ($name; $names)
		If (Length($name)=0)
			$out.push(This._issue("error"; "METHOD_WHITELIST"; "An action has an empty name."))
			continue
		End if 
		var $spec : Variant
		$spec:=$wl[$name]
		If (Value type($spec)#Is object)
			$out.push(This._issue("error"; "METHOD_WHITELIST"; $name+": the spec must be an object."))
			continue
		End if 
		If (Length(String($spec.method))=0)
			$out.push(This._issue("error"; "METHOD_WHITELIST"; $name+": no host method named — call_method would have nothing to execute."))
		End if 
		If ($spec.args=Null)
			continue
		End if 
		If (Value type($spec.args)#Is collection)
			$out.push(This._issue("error"; "METHOD_WHITELIST"; $name+": args must be an ordered list."))
			continue
		End if 
		var $seenOptional : Boolean
		$seenOptional:=False
		var $i : Integer
		$i:=0
		var $arg : Variant
		For each ($arg; $spec.args)
			$i:=$i+1
			If (Value type($arg)#Is object)
				$out.push(This._issue("error"; "METHOD_WHITELIST"; $name+": argument "+String($i)+" is not an object."))
				continue
			End if 
			If (Length(String($arg.name))=0)
				$out.push(This._issue("warning"; "METHOD_WHITELIST"; \
					$name+": argument "+String($i)+" has no name (documentation only, but clients see it)."))
			End if 
			If ($types.indexOf(String($arg.type))<0)
				$out.push(This._issue("error"; "METHOD_WHITELIST"; \
					$name+": argument "+String($i)+" has type \""+String($arg.type)+"\" — must be one of "+$types.join(", ")+"."))
			End if 
			If (Bool($arg.required))
				If ($seenOptional)
					$out.push(This._issue("error"; "METHOD_WHITELIST"; \
						$name+": required argument "+String($i)+" follows an optional one. 4D binds args positionally, so optional args must be trailing."))
				End if 
			Else 
				$seenOptional:=True
			End if 
		End for each 
	End for each 
	return $out
	
	// =============================================================================
	//  Helpers
	// =============================================================================
	
Function _issue($severity : Text; $key : Text; $message : Text) : Object
	return New object("severity"; $severity; "key"; $key; "message"; $message)
	
	// _dataclassExists: case-insensitive, matching ds[...] resolution — the same
	// leniency MCP_Schema applies when it resolves config table names.
Function _dataclassExists($name : Text) : Boolean
	var $all : Collection
	$all:=This.dataclassNames()
	If ($all.length=0)
		return True  // no datastore to check against: don't cry wolf
	End if 
	var $n : Text
	For each ($n; $all)
		If (Lowercase($n)=Lowercase($name))
			return True
		End if 
	End for each 
	return False
	
Function _lastErrorText() : Text
	var $errs : Collection
	$errs:=Last errors
	If ($errs=Null)
		return "Unknown 4D error"
	End if 
	If ($errs.length=0)
		return "Unknown 4D error"
	End if 
	var $msgs : Collection
	$msgs:=New collection
	var $e : Object
	For each ($e; $errs)
		$msgs.push(String($e.message))
	End for each 
	return $msgs.join("; ")
	