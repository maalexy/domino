import 'dart:convert';

import 'package:code_builder/code_builder.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:dart_style/dart_style.dart';
import 'package:meta/meta.dart';
import 'package:xml/xml.dart';

import 'canonical.dart';

class GeneratedSource {
  final String dartFileContent;
  final String sassFileContent;

  GeneratedSource({
    @required this.dartFileContent,
    @required this.sassFileContent,
  });

  bool get hasSassFileContent =>
      sassFileContent != null && sassFileContent.isNotEmpty;
}

GeneratedSource parseHtmlToSources(String htmlContent) {
  final ps = parseToCanonical(htmlContent);
  final cg = _ComponentGenerator();
  final library = cg.generateLibrary(ps);

  final emitter = DartEmitter(Allocator.simplePrefixing());
  final dartFileContent = DartFormatter().format('${library.accept(emitter)}');

  final sassFileContent = cg.generateScss(ps).trim();
  return GeneratedSource(
    dartFileContent: dartFileContent,
    sassFileContent: sassFileContent,
  );
}

final _idomUri = 'package:domino/src/experimental/idom.dart';
final _required = refer('required', 'package:meta/meta.dart');

class _ComponentGenerator {
  final _texts = <_TextElem>[];
  final _i18n = false;

  Library generateLibrary(ParsedSource parsed) {
    return Library((lib) {
      for (final template in parsed.templates) {
        final name = template.getAttribute('method-name', namespace: dominoNs);

        final topLevelObjects = <String>[];
        lib.body.add(Method.returnsVoid((m) {
          m.name = name;
          m.requiredParameters.add(Parameter((p) {
            p.name = r'$d';
            p.type = refer('DomContext', _idomUri);
          }));

          final defaultInits = <String>[];

          for (final ve in template
              .findElements('template-var', namespace: dominoNs)
              .toList()) {
            final library = ve.getDominoAttr('library');
            final type = ve.getDominoAttr('type');
            final name = ve.getDominoAttr('name');
            final defaultValue = ve.getDominoAttr('default');
            final documentation = ve.getDominoAttr('doc');
            final required = ve.getDominoAttr('required') == 'true';
            ve.parent.children.remove(ve);
            m.optionalParameters.add(Parameter((p) {
              p.name = name;
              p.type = refer(type, library);
              p.named = true;
              if (documentation != null) {
                p.docs.addAll(documentation.split('\n').map((l) => '/// $l'));
              }
              if (required) p.annotations.add(_required);
            }));

            if (defaultValue != null) {
              defaultInits.add('$name ??= $defaultValue;');
            }
          }
          m.body = Code.scope((allocator) {
            final code = StringBuffer();
            defaultInits.forEach(code.writeln);
            _render(code, allocator, Stack(objects: topLevelObjects),
                template.nodes);
            if (_texts.isNotEmpty) {
              code.writeln('const _\$strings = {');
              final snames = <String>{};
              for (final te in _texts) {
                snames.add(te.name);
              }
              for (final sn in snames) {
                code.writeln('r\'$sn\': {');
                final usedLangs = <String>{};
                for (final te in _texts.where((te) => te.name == sn)) {
                  if (usedLangs.contains(te.lang)) continue;
                  usedLangs.add(te.lang);
                  code.writeln('\'_params${te.lang}\': r\'${te.params}\',');
                  code.writeln('\'${te.lang}\': r\'${te.text}\',');
                }
                code.writeln('},');
              }
              code.writeln('};');
            }
            return code.toString();
          });
        }));
      }
    });
  }

  String _scssName(XmlElement style) {
    // hash of the content
    final hash =
        sha256.convert(utf8.encode(style.text)).toString().substring(0, 20);
    // TODO: include template name as part of the name
    // TODO: include parent element tag as part of the name
    return ['ds', hash].join('_');
  }

  void _render(StringBuffer code, String Function(Reference ref) allocator,
      Stack stack, Iterable<XmlNode> nodes) {
    for (final node in nodes) {
      if (node is XmlElement) {
        if (_isDominoElem(node, 'for')) {
          final expr = node.getDominoAttr('expr').split(' in ');
          final object = expr[0].trim();
          final ns = Stack(parent: stack, objects: [object]);
          code.writeln(
              'for (final $object in ${stack.canonicalize(expr[1].trim())}) {');
          _render(code, allocator, ns, node.nodes);
          code.writeln('}');
        } else if (_isDominoElem(node, 'if')) {
          final cond = node.getDominoAttr('expr');
          code.writeln('if (${stack.canonicalize(cond)}) {');
          _render(code, allocator, stack, node.nodes);
          code.writeln('}');
        } else if (_isDominoElem(node, 'else-if')) {
          final cond = node.getDominoAttr('expr');
          code.writeln('else if (${stack.canonicalize(cond)}) {');
          _render(code, allocator, stack, node.nodes);
          code.writeln('}');
        } else if (_isDominoElem(node, 'else')) {
          code.writeln('else {');
          _render(code, allocator, stack, node.nodes);
          code.writeln('}');
        } else if (_isDominoElem(node, 'call')) {
          _renderCall(code, allocator, stack, node);
        } else if (_isDominoElem(node, 'attr')) {
          _renderAttr(code, stack, node);
        } else if (_isDominoElem(node, 'class')) {
          _renderClass(code, stack, node);
        } else if (_isDominoElem(node, 'slot')) {
          _renderSlot(code, stack, node);
        } else if (_isDominoElem(node, 'style')) {
          _renderStyle(code, stack, node);
        } else {
          _renderElem(code, allocator, stack, node);
        }
      } else if (node is XmlText) {
        final nodeText = node.text;
        if (nodeText.isEmpty || nodeText.trim().isEmpty) continue;
        _renderText(code, stack, nodeText);
      } else if (node is XmlComment) {
        code.writeln('/*${node.text}*/');
      } else if (node is XmlAttribute) {
        //
      } else {
        throw UnsupportedError('Node: ${node.runtimeType}');
      }
    }
  }

  static final _whitespace = RegExp(r'\s+');
  static final _word = RegExp(r'\w+');
  void _renderText(StringBuffer code, Stack stack, String nodeText) {
    if (!_i18n) {
      code.writeln('    \$d.text(\'${_interpolateText(stack, nodeText)}\');');
      return;
    }

    final text = nodeText.trim().replaceAll(_whitespace, ' ');
    if (text.isEmpty) return; // empty line
    final fnName = _textFn(text);

    final parts = _interpolateTextParts(stack, text);
    var cnt = 0;
    final argNames = StringBuffer();
    final newText = StringBuffer();
    final params = <String, String>{};
    for (final part in parts) {
      if (part.startsWith('\$')) {
        params['\$arg$cnt'] = part.substring(2, part.length - 1);
        newText.write('\$arg$cnt');

        if (cnt > 0) argNames.write(',');
        argNames.write('\$arg$cnt');
        cnt++;
      } else {
        newText.write(part);
      }
    }
    final textelem = _TextElem(fnName, newText.toString(), params: params);
    _texts.add(textelem);

    // Functions need to be used for interpolation.
    code.writeln('{    String $fnName($argNames) => '
        '(_\$strings[r\'$fnName\'].containsKey(\$d.globals.locale)'
        '? _\$strings[r\'$fnName\'][\$d.globals.locale]'
        ': _\$strings[r\'$fnName\'][\'\'])');
    code.writeln('.toString()');
    params.forEach((key, value) {
      code.writeln('      .replaceAll(r\'$key\', $key.toString())');
    });
    code.writeln(';');

    // second is a call to the function with the real parameters
    code.writeln(
        '    \$d.text($fnName(${textelem.params.values.join(',')}));}');
  }

  String _textFn(String text) {
    final wordParts = _word
        .allMatches(text)
        .map((e) => e.group(0).toLowerCase())
        .map((v) => v.length <= 1
            ? v.toUpperCase()
            : v.substring(0, 1).toUpperCase() + v.substring(1).toLowerCase())
        .take(5)
        .toList();
    final wordId = StringBuffer();
    for (var i = 0; i < wordParts.length; i++) {
      wordId.write(wordParts[i]);
      if (i >= 2 && wordId.length > 20) break;
    }

    final textHash =
        sha256.convert(utf8.encode(text)).toString().substring(0, 8);
    return 't$textHash\$$wordId';
  }

  void _renderElem(StringBuffer code, String Function(Reference ref) allocator,
      Stack stack, XmlElement elem) {
    final tag = elem.name.local == 'element'
        ? elem.getDominoAttr('tag')
        : elem.name.local;
    final key = elem.removeDominoAttr('key');
    final openParams = <String>[];
    if (key != null) {
      openParams.add(', key: $key');
    }

    code.writeln('    \$d.open(\'$tag\' ${openParams.join()});');
    for (final attr in elem.attributes) {
      if (attr.name.namespaceUri != null) continue;
      code.writeln(
          '    \$d.attr(\'${attr.name.local}\', \'${_interpolateText(stack, attr.value)}\');');
    }

    // d-var attributes
    for (final dattr
        in elem.attributes.where((attr) => attr.name.namespaceUri == null)) {
      if (dattr.name.local.startsWith('var-')) {
        final valname = dartName(dattr.name.local.split('-')[1]);
        code.writeln('\n    var $valname;');
      }
    }
    // 'd-' attributes
    for (final dattr in elem.attributes
        .where((attr) => attr.name.namespaceUri == dominoNs)) {
      final attr = dattr.name.local;
      // Single d:event-onclick=dartFunction
      if (attr.startsWith('event-on')) {
        final parts = attr.split('-');
        final eventName = parts[1].substring(2);
        code.writeln(
            '    \$d.event(\'$eventName\', fn: ${_interpolateText(stack, dattr.value)});');
      }
      if (attr.startsWith('event-list-')) {
        code.writeln('''
        for(final key in ${_interpolateText(stack, dattr.value)}.keys) {
            \$d.event(key, fn: ${_interpolateText(stack, dattr.value)}[key]);
        }
        ''');
      }

      if (attr.startsWith('bind-input-')) {
        final ba = attr.split('-').sublist(2).join('-'); // binded attribute
        final ex = dattr.value; // expression
        code.writeln('''{
          final elem = \$d.element;
          elem.$ba = $ex;
          \$d.event('input', fn: (event) {
             $ex = elem.$ba;
          });
          \$d.event('change', fn: (event) {
             $ex = elem.$ba;
          });
        }'''); // TODO: add some way to clean up reference
      }
    }

    _render(code, allocator, stack, elem.nodes);
    code.writeln('    \$d.close();');
  }

  void _renderCall(StringBuffer code, String Function(Reference ref) allocator,
      Stack stack, XmlElement elem) {
    final library = elem.removeDominoAttr('library');
    final method = elem.removeDominoAttr('method') ?? '';

    code.write(allocator(refer(method, library)));
    code.write('(\$d');

    for (final ch in elem.elements) {
      if (ch.name.local == 'call-var') {
        code.write(
            ', ${ch.getDominoAttr('name')}:${ch.getDominoAttr('value')}');
      }
      if (ch.name.local == 'call-slot') {
        final dcFQN = allocator(refer('DomContext', _idomUri));
        code.writeln(', ${ch.getDominoAttr('name')}: ($dcFQN \$d) {');
        _render(code, allocator, stack, ch.nodes);
        code.writeln('}');
      }
    }

    code.writeln(');');
  }

  // Returns a list where each element is either text
  // or a string for interpolation
  List<String> _interpolateTextParts(Stack stack, String value) {
    final parts = <String>[];

    void addText(String v) {
      final x = v
          .replaceAll('\'', '\\\'')
          .replaceAll(r'$', r'\$')
          .replaceAll('\n', r'\n');
      if (x.isNotEmpty) {
        parts.add(x);
      }
    }

    final matches = _expr.allMatches(value);
    var pos = 0;
    for (final m in matches) {
      if (pos < m.start) {
        addText(value.substring(pos, m.start));
      }
      var e = m.group(1).trim();
      if (e != '\' \'') {
        e = stack.canonicalize(e);
      }
      parts.add('\${$e}');
      pos = m.end;
    }
    if (pos < value.length) {
      addText(value.substring(pos));
    }
    return parts;
  }

  String _interpolateText(Stack stack, String value) {
    return _interpolateTextParts(stack, value).join();
  }

  void _renderAttr(StringBuffer code, Stack stack, XmlElement elem) {
    final name = elem.getDominoAttr('name');
    final value = _interpolateText(stack, elem.getDominoAttr('value'));
    code.writeln('\$d.attr(\'$name\', $value);');
  }

  void _renderClass(StringBuffer code, Stack stack, XmlElement elem) {
    final nameAttr = elem.getDominoAttr('name');
    final name = _interpolateText(stack, nameAttr);
    final presentAttr = elem.getDominoAttr('present');
    final present =
        presentAttr == null ? '' : ', ${_interpolateText(stack, presentAttr)}';
    code.writeln('\$d.clazz(\'$name\'$present);');
  }

  void _renderSlot(StringBuffer code, Stack stack, XmlElement elem) {
    final method = elem.removeDominoAttr('name');
    code.writeln('if ($method != null) {$method(\$d);}');
  }

  void _renderStyle(StringBuffer code, Stack stack, XmlElement elem) {
    final cn = _scssName(elem);
    code.writeln('    \$d.clazz(\'$cn\');\n');
  }

  String generateScss(ParsedSource parsedSource) {
    final data = StringBuffer();
    for (final template in parsedSource.templates) {
      final styles = template.findAllElements('style', namespace: dominoNs);
      for (final elem in styles) {
        data.writeln('.${_scssName(elem)} {');
        final lines = elem.text.split('\n');
        var indent = 1;
        for (final line in lines) {
          final lt = line.trim();
          if (lt.isEmpty) continue;
          if (lt == '}') {
            data.write('  ' * (indent - 1));
          } else {
            data.write('  ' * indent);
          }
          data.writeln(lt);
          indent += line.split('{').length - line.split('}').length;
        }
        data.writeln('}');
      }
    }
    return data.toString();
  }
}

// Matches strings for interpolation
final _expr = RegExp('{{(.+?)}}');

class Stack {
  final Stack _parent;
  final Set<String> _objects;
  final bool _emitWhitespaces;

  Stack({
    Stack parent,
    bool emitWhitespaces,
    Iterable<String> objects,
  })  : _parent = parent,
        _objects = objects?.toSet() ?? <String>{},
        _emitWhitespaces = emitWhitespaces;

  bool get emitWhitespaces =>
      _emitWhitespaces ?? _parent?.emitWhitespaces ?? false;

  String canonicalize(String expr) {
    var s = this;
    while (s != null) {
      if (s._objects.any((o) => expr.contains(o))) {
        return expr;
      }
      s = s._parent;
    }
    // TODO: log suspicious expression
    return expr;
  }
}

bool _isDominoElem(XmlElement elem, String tag) =>
    elem.name.namespaceUri == dominoNs && elem.name.local == tag;

class _TextElem {
  final String name;
  final Map<String, String> params;
  final String text;
  final String lang;
  _TextElem._(this.name, this.text, this.lang, this.params);
  factory _TextElem(String name, String text,
      {String lang, Map<String, String> params}) {
    return _TextElem._(name, text, lang ?? '', params ?? {});
  }
}
