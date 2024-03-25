import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'package:json_annotation/json_annotation.dart';

class PostProcessGenerator extends GeneratorForAnnotation<JsonSerializable> {
  @override
  Future<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) async {
    if (element is! ClassElement) {
      return '';
    }

    final className = element.name;
    final buffer = StringBuffer();

    // Add additional methods or logic here
    buffer.writeln('extension ${className}JsonExtension on $className {');
    buffer.writeln('  factory $className.fromJson(Map<String, dynamic> json) => _\$${className}FromJson(json);');
    buffer.writeln('  Map<String, dynamic> toJson() => _\$${className}ToJson(this);');
    buffer.writeln('}');

    return buffer.toString();
  }
}
