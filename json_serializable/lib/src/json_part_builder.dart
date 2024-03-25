// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:build/build.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:json_serializable/src/generator_helper.dart';
import 'package:source_gen/source_gen.dart';

import 'check_dependencies.dart';
import 'json_enum_generator.dart';
import 'json_literal_generator.dart';
import 'json_serializable_generator.dart';
import 'settings.dart';

/// Returns a [Builder] for use within a `package:build_runner`
/// `BuildAction`.
///
/// [formatOutput] is called to format the generated code. If not provided,
/// the default Dart code formatter is used.
Builder jsonPartBuilder({
  String Function(String code)? formatOutput,
  JsonSerializable? config,
}) {
  final settings = Settings(config: config);

  return SharedPartBuilder(
    [
      _UnifiedGenerator([
        JsonSerializableGenerator.fromSettings(settings),
        const JsonEnumGenerator(),
      ]),
      const JsonLiteralGenerator(),
    ],
    'json_serializable',
    formatOutput: formatOutput,
  );
}

/// Allows exposing separate [GeneratorForAnnotation] instances as one
/// generator.
///
/// We want duplicate items to be merged if folks use both `@JsonEnum` and
/// `@JsonSerializable` so we don't get duplicate enum helper functions.
///
/// This can only be done if the output is merged into one generator.
///
/// This class allows us to keep the implementations separate.
class _UnifiedGenerator extends Generator {
  final List<GeneratorForAnnotation> _generators;

  _UnifiedGenerator(this._generators);

  @override
  Future<String?> generate(LibraryReader library, BuildStep buildStep) async {
    final values = <String>{};

    for (var generator in _generators) {
      for (var annotatedElement
          in library.annotatedWith(generator.typeChecker)) {
        await pubspecHasRightVersion(buildStep);

        final generatedValue = generator.generateForAnnotatedElement(
            annotatedElement.element, annotatedElement.annotation, buildStep);
        for (var value in _normalizeGeneratorOutput(generatedValue)) {
          assert(value.length == value.trim().length);
          values.add(value);
        }
      }
    }

    List<Map<String, dynamic>> modifications = [];

    for (var generator in _generators) {
      if (generator is JsonSerializableGenerator) {
        for (var annotatedElement
            in library.annotatedWith(generator.typeChecker)) {
          var modification = await generator.addToJSONAndFromJSONToClasses(
              annotatedElement.element, annotatedElement.annotation, buildStep);
          modifications.add(modification);
        }
      }
    }

    modifications.sort((a, b) =>
        (b['startOffset'] as int).compareTo((a['startOffset'] as int)));
    for (var modification in modifications) {
      var filePath = modification['filePath'] as String;
      var startOffset = modification['startOffset'] as int;
      var endOffset = modification['endOffset'] as int;
      var newClassSource = modification['newClassSource'] as String;

      // Read the existing content of the file.
      var fileContent = await File(filePath).readAsString();

      // Apply the modification.
      var updatedContent = fileContent.substring(0, startOffset) +
          newClassSource +
          fileContent.substring(endOffset);

      // Overwrite the file with the updated content.
      await File(filePath).writeAsString(updatedContent);
    }

    return values.join('\n\n');
  }

  @override
  String toString() => 'JsonSerializableGenerator';
// Borrowed from `package:source_gen`
  Iterable<String> _normalizeGeneratorOutput(Object? value) {
    if (value == null) {
      return const [];
    } else if (value is String) {
      value = [value];
    }

    if (value is Iterable) {
      return value.where((e) => e != null).map((e) {
        if (e is String) {
          return e.trim();
        }

        throw _argError(e as Object);
      }).where((e) => e.isNotEmpty);
    }
    throw _argError(value);
  }

// Borrowed from `package:source_gen`
  ArgumentError _argError(Object value) => ArgumentError(
      'Must be a String or be an Iterable containing String values. '
      'Found `${Error.safeToString(value)}` (${value.runtimeType}).');
}
