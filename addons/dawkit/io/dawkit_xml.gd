class_name DawKitXml
extends RefCounted

## A small XML element tree: enough to write a DAWproject file and read one back, and nothing
## else. Godot reads XML with XMLParser, a pull parser; this turns its stream into elements a
## reader can walk, and turns elements back into text.

var tag := ""
## Attribute name -> value, in the order they were set (which is the order they are written).
var attrs := {}
var children: Array[DawKitXml] = []
var text := ""


func _init(with_tag := "", with_attrs := {}) -> void:
	tag = with_tag
	attrs = with_attrs


## Appends a child element and returns it.
func add(child_tag: String, child_attrs := {}) -> DawKitXml:
	var c := DawKitXml.new(child_tag, child_attrs)
	children.append(c)
	return c


## The first child with this tag, or null.
func first(child_tag: String) -> DawKitXml:
	for c in children:
		if c.tag == child_tag:
			return c
	return null


## Every child with this tag (any of them, when given several).
func all(child_tags) -> Array[DawKitXml]:
	var wanted: Array = child_tags if child_tags is Array else [child_tags]
	var out: Array[DawKitXml] = []
	for c in children:
		if c.tag in wanted:
			out.append(c)
	return out


func get_attr(name: String, fallback := "") -> String:
	return str(attrs.get(name, fallback))


func get_float(name: String, fallback := 0.0) -> float:
	return float(attrs[name]) if attrs.has(name) and str(attrs[name]).is_valid_float() else fallback


func get_bool(name: String, fallback := false) -> bool:
	if not attrs.has(name):
		return fallback
	return str(attrs[name]).to_lower() in ["true", "1"]


## A number as text that reads back as exactly the same number.
static func num(x: float) -> String:
	return String.num_scientific(x)


static func flag(b: bool) -> String:
	return "true" if b else "false"


func to_text() -> String:
	var lines := PackedStringArray(['<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'])
	_write(lines, 0)
	return "\n".join(lines) + "\n"


func _write(lines: PackedStringArray, depth: int) -> void:
	var pad := "  ".repeat(depth)
	var head := "<" + tag
	for k in attrs:
		head += ' %s="%s"' % [k, _escape(str(attrs[k]))]
	if children.is_empty() and text.is_empty():
		lines.append(pad + head + "/>")
		return
	if children.is_empty():
		lines.append(pad + head + ">" + _escape(text) + "</" + tag + ">")
		return
	lines.append(pad + head + ">")
	for c in children:
		c._write(lines, depth + 1)
	lines.append(pad + "</" + tag + ">")


static func _escape(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


## The document's root element, or null when it is not well-formed.
static func parse(bytes: PackedByteArray) -> DawKitXml:
	var p := XMLParser.new()
	if p.open_buffer(bytes) != OK:
		return null
	var root: DawKitXml = null
	var stack: Array[DawKitXml] = []
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				var e := DawKitXml.new(p.get_node_name())
				for i in p.get_attribute_count():
					e.attrs[p.get_attribute_name(i)] = p.get_attribute_value(i)
				if stack.is_empty():
					if root != null:
						return null
					root = e
				else:
					stack.back().children.append(e)
				if not p.is_empty():
					stack.append(e)
			XMLParser.NODE_ELEMENT_END:
				if stack.is_empty() or stack.back().tag != p.get_node_name():
					return null
				stack.pop_back()
			XMLParser.NODE_TEXT:
				if not stack.is_empty():
					stack.back().text += p.get_node_data().strip_edges()
	return root if stack.is_empty() else null
