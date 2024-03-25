// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// ignore_for_file: lines_longer_than_80_chars, omit_local_variable_types, directives_ordering

import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';

import '../type_helper.dart';
import 'decode_helper.dart';
import 'encoder_helper.dart';
import 'field_helpers.dart';
import 'helper_core.dart';
import 'settings.dart';
import 'utils.dart';

class GeneratorHelper extends HelperCore with EncodeHelper, DecodeHelper {
  final Settings _generator;
  final _addedMembers = <String>{};
  Uri? fileLocation;
  BuildStep? buildStep;

  GeneratorHelper(
      this._generator, ClassElement element, ConstantReader annotation,
      {this.fileLocation, this.buildStep})
      : super(
            element,
            mergeConfig(
              _generator.config,
              annotation,
              classElement: element,
            ));

  @override
  void addMember(String memberContent) {
    _addedMembers.add(memberContent);
  }

  @override
  Iterable<TypeHelper> get allTypeHelpers => _generator.allHelpers;

  Future<Map<String, dynamic>> addToJSONAndFromJSONToClasses() async {
    final assetId = buildStep!.inputId;
    var sourcePath = await buildStep!.canRead(assetId) ? assetId.path : null;

    if (sourcePath == null) {
      return {};
    }
    final projectRoot = Directory.current.path;
    sourcePath = p.join(projectRoot, assetId.path);
    sourcePath = p.normalize(sourcePath);
    final collection = AnalysisContextCollection(includedPaths: [sourcePath]);
    final analysisContext = collection.contextFor(sourcePath);
    final result = analysisContext.currentSession.getParsedUnit(sourcePath);

    final className = element.name;
    if (result is ParsedUnitResult) {
      final unit = result.unit;

      // Find the class declaration
      final classDeclaration =
          unit.declarations.whereType<ClassDeclaration>().firstWhere(
                (decl) => decl.name.toString() == className,
                orElse: () => throw Exception('Class not found'),
              );

      final newClass = Class((builder) {
        builder
          ..name = element.name
          ..extend = Reference(
              element.supertype!.getDisplayString(withNullability: false));

        // Copy constructors
        for (var constructor in element.constructors) {
          builder.constructors.add(Constructor((cBuilder) {
            cBuilder
              ..name = constructor.name
              ..requiredParameters.addAll(constructor.parameters
                  .where((param) =>
                      param.isRequiredPositional || param.isRequiredNamed)
                  .map((param) => Parameter((pBuilder) => pBuilder
                    ..name = param.name
                    ..type = refer(
                        param.type.getDisplayString(withNullability: true)))))
              ..optionalParameters.addAll(constructor.parameters
                  .where((param) =>
                      param.isOptionalPositional || param.isOptionalNamed)
                  .map((param) => Parameter((pBuilder) => pBuilder
                    ..name = param.name
                    ..type = refer(
                        param.type.getDisplayString(withNullability: true))
                    ..defaultTo = (param.defaultValueCode != null)
                        ? Code(param.defaultValueCode!)
                        : null
                    ..named = param.isNamed
                    ..required = param.isRequiredNamed)));
          }));
        }

        // Copy fields
        for (var field in element.fields) {
          if (!field.isStatic) {
            var fieldBuilder = FieldBuilder()
              ..name = field.name
              ..type =
                  refer(field.type.getDisplayString(withNullability: true));

            // Conditionally set the field as final
            if (field.isFinal) {
              fieldBuilder.modifier = FieldModifier.final$;
            } else {
              fieldBuilder.modifier = FieldModifier.var$;
            }

            // Add the field to the class builder
            builder.fields.add(fieldBuilder.build());
          }
        }

        // Copy methods
        for (var method in element.methods) {
          if (!method.isStatic) {
            builder.methods.add(Method((m) => m
              ..name = method.name
              ..returns = refer(
                  method.returnType.getDisplayString(withNullability: true))
              ..requiredParameters.addAll(method.parameters
                  .where((param) =>
                      param.isRequiredPositional || param.isRequiredNamed)
                  .map((param) => Parameter((pBuilder) => pBuilder
                    ..name = param.name
                    ..type = refer(
                        param.type.getDisplayString(withNullability: true)))))
              ..optionalParameters.addAll(method.parameters
                  .where((param) =>
                      param.isOptionalPositional || param.isOptionalNamed)
                  .map((param) => Parameter((pBuilder) => pBuilder
                    ..name = param.name
                    ..type = refer(
                        param.type.getDisplayString(withNullability: true))
                    ..defaultTo = (param.defaultValueCode != null)
                        ? Code(param.defaultValueCode!)
                        : null
                    ..named = param.isNamed
                    ..required = param.isRequiredNamed)))
              ..body = Code(method.source.toString())));
          }
        }

        // Add toJson method
        builder.methods.add(Method((m) => m
          ..name = 'toJson'
          ..returns = const Reference('Map<String, dynamic>')
          ..body = Code('return _\$${element.name}ToJson(this);')));

        builder.constructors.add(Constructor((c) => c
          ..name = 'fromJson'
          ..factory = true
          ..requiredParameters.add(Parameter((p) => p
            ..name = 'json'
            ..type = Reference('Map<String, dynamic>')))
          ..body = Code('return _\$${element.name}FromJson(json);')));
      });
      final classSpec = newClass.toBuilder().build();
      final emitter = DartEmitter();
      final newClassSource = '${classSpec.accept(emitter)}';

      return {
        'filePath': sourcePath,
        'startOffset': classDeclaration.offset,
        'endOffset': classDeclaration.end,
        'newClassSource': newClassSource,
      };
    }
    return {};
  }

  Iterable<String> generate() sync* {
    assert(_addedMembers.isEmpty);

    if (config.genericArgumentFactories && element.typeParameters.isEmpty) {
      log.warning(
        'The class `${element.displayName}` is annotated '
        'with `JsonSerializable` field `genericArgumentFactories: true`. '
        '`genericArgumentFactories: true` only affects classes with type '
        'parameters. For classes without type parameters, the option is '
        'ignored.',
      );
    }

    final sortedFields = createSortedFieldSet(element);

    // Used to keep track of why a field is ignored. Useful for providing
    // helpful errors when generating constructor calls that try to use one of
    // these fields.
    final unavailableReasons = <String, String>{};

    final accessibleFields = sortedFields.fold<Map<String, FieldElement>>(
      <String, FieldElement>{},
      (map, field) {
        final jsonKey = jsonKeyFor(field);
        if (!field.isPublic && !jsonKey.explicitYesFromJson) {
          unavailableReasons[field.name] = 'It is assigned to a private field.';
        } else if (field.getter == null) {
          assert(field.setter != null);
          unavailableReasons[field.name] =
              'Setter-only properties are not supported.';
          log.warning('Setters are ignored: ${element.name}.${field.name}');
        } else if (jsonKey.explicitNoFromJson) {
          unavailableReasons[field.name] =
              'It is assigned to a field not meant to be used in fromJson.';
        } else {
          assert(!map.containsKey(field.name));
          map[field.name] = field;
        }

        return map;
      },
    );

    var accessibleFieldSet = accessibleFields.values.toSet();
    if (config.createFactory) {
      final createResult = createFactory(accessibleFields, unavailableReasons);
      yield createResult.output;

      final fieldsToUse = accessibleFields.entries
          .where((e) => createResult.usedFields.contains(e.key))
          .map((e) => e.value)
          .toList();

      // Need to add candidates BACK even if they are not used in the factory if
      // they are forced to be used for toJSON
      for (var candidate in sortedFields.where((element) =>
          jsonKeyFor(element).explicitYesToJson &&
          !fieldsToUse.contains(element))) {
        fieldsToUse.add(candidate);
      }

      // Need the fields to maintain the original source ordering
      fieldsToUse.sort(
          (a, b) => sortedFields.indexOf(a).compareTo(sortedFields.indexOf(b)));

      accessibleFieldSet = fieldsToUse.toSet();
    }

    accessibleFieldSet
      ..removeWhere(
        (element) => jsonKeyFor(element).explicitNoToJson,
      )

      // Check for duplicate JSON keys due to colliding annotations.
      // We do this now, since we have a final field list after any pruning done
      // by `_writeCtor`.
      ..fold(
        <String>{},
        (Set<String> set, fe) {
          final jsonKey = nameAccess(fe);
          if (!set.add(jsonKey)) {
            throw InvalidGenerationSourceError(
              'More than one field has the JSON key for name "$jsonKey".',
              element: fe,
            );
          }
          return set;
        },
      );

    if (config.createFieldMap) {
      yield createFieldMap(accessibleFieldSet);
    }

    if (config.createJsonKeys) {
      yield createJsonKeys(accessibleFieldSet);
    }

    if (config.createPerFieldToJson) {
      yield createPerFieldToJson(accessibleFieldSet);
    }

    if (config.createToJson) {
      yield* createToJson(accessibleFieldSet);
    }

    addToJSONAndFromJSONToClasses();

    yield* _addedMembers;
  }
}

extension on KeyConfig {
  bool get explicitYesFromJson => includeFromJson == true;

  bool get explicitNoFromJson => includeFromJson == false;

  bool get explicitYesToJson => includeToJson == true;

  bool get explicitNoToJson => includeToJson == false;
}
