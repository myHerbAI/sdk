// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/declared_variables.dart';
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/source/source.dart';
import 'package:analyzer/src/context/source.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart' as file_state;
import 'package:analyzer/src/dart/analysis/file_state.dart';
import 'package:analyzer/src/dart/analysis/testing_data.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';
import 'package:analyzer/src/dart/constant/compute.dart';
import 'package:analyzer/src/dart/constant/constant_verifier.dart';
import 'package:analyzer/src/dart/constant/evaluation.dart';
import 'package:analyzer/src/dart/constant/utilities.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/inheritance_manager3.dart';
import 'package:analyzer/src/dart/element/type_provider.dart';
import 'package:analyzer/src/dart/element/type_system.dart';
import 'package:analyzer/src/dart/resolver/flow_analysis_visitor.dart';
import 'package:analyzer/src/dart/resolver/resolution_visitor.dart';
import 'package:analyzer/src/error/best_practices_verifier.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/error/constructor_fields_verifier.dart';
import 'package:analyzer/src/error/dead_code_verifier.dart';
import 'package:analyzer/src/error/ignore_validator.dart';
import 'package:analyzer/src/error/imports_verifier.dart';
import 'package:analyzer/src/error/inheritance_override.dart';
import 'package:analyzer/src/error/language_version_override_verifier.dart';
import 'package:analyzer/src/error/override_verifier.dart';
import 'package:analyzer/src/error/redeclare_verifier.dart';
import 'package:analyzer/src/error/todo_finder.dart';
import 'package:analyzer/src/error/unicode_text_verifier.dart';
import 'package:analyzer/src/error/unused_local_elements_verifier.dart';
import 'package:analyzer/src/generated/element_walker.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/error_verifier.dart';
import 'package:analyzer/src/generated/ffi_verifier.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/hint/sdk_constraint_verifier.dart';
import 'package:analyzer/src/ignore_comments/ignore_info.dart';
import 'package:analyzer/src/lint/linter.dart';
import 'package:analyzer/src/lint/linter_visitor.dart';
import 'package:analyzer/src/services/lint.dart';
import 'package:analyzer/src/task/strong/checker.dart';
import 'package:analyzer/src/util/performance/operation_performance.dart';
import 'package:analyzer/src/utilities/extensions/version.dart';
import 'package:analyzer/src/workspace/pub.dart';
import 'package:path/path.dart' as path;

class AnalysisForCompletionResult {
  final CompilationUnit parsedUnit;
  final List<AstNode> resolvedNodes;

  AnalysisForCompletionResult({
    required this.parsedUnit,
    required this.resolvedNodes,
  });
}

/// Analyzer of a single library.
class LibraryAnalyzer {
  final AnalysisOptionsImpl _analysisOptions;
  final DeclaredVariables _declaredVariables;
  final LibraryFileKind _library;
  final InheritanceManager3 _inheritance;
  final path.Context _pathContext;

  final LibraryElementImpl _libraryElement;

  final Map<FileState, LineInfo> _fileToLineInfo = {};

  final Map<FileState, IgnoreInfo> _fileToIgnoreInfo = {};
  final Map<FileState, RecordingErrorListener> _errorListeners = {};
  final Map<FileState, ErrorReporter> _errorReporters = {};
  late final LibraryVerificationContext _libraryVerificationContext;

  final TestingData? _testingData;
  final TypeSystemOperations _typeSystemOperations;

  LibraryAnalyzer(this._analysisOptions, this._declaredVariables,
      this._libraryElement, this._inheritance, this._library, this._pathContext,
      {TestingData? testingData,
      required TypeSystemOperations typeSystemOperations})
      : _testingData = testingData,
        _typeSystemOperations = typeSystemOperations {
    _libraryVerificationContext = LibraryVerificationContext(
      constructorFieldsVerifier: ConstructorFieldsVerifier(
        typeSystem: _typeSystem,
      ),
    );
  }

  TypeProviderImpl get _typeProvider => _libraryElement.typeProvider;

  TypeSystemImpl get _typeSystem => _libraryElement.typeSystem;

  /// Compute analysis results for all units of the library.
  List<UnitAnalysisResult> analyze() {
    var units = _parseAndResolve();
    _computeDiagnostics(units);

    // Return full results.
    var results = <UnitAnalysisResult>[];
    units.forEach((file, unit) {
      var errors = _getErrorListener(file).errors;
      errors = _filterIgnoredErrors(file, errors);
      results.add(UnitAnalysisResult(file, unit, errors));
    });
    return results;
  }

  /// Analyze [file] for a completion result.
  ///
  /// This method aims to avoid work that [analyze] does which would be
  /// unnecessary for a completion request.
  AnalysisForCompletionResult analyzeForCompletion({
    required FileState file,
    required int offset,
    required CompilationUnitElementImpl unitElement,
    required OperationPerformanceImpl performance,
  }) {
    var parsedUnit = performance.run('parse', (performance) {
      return _parse(file);
    });
    parsedUnit.declaredElement = unitElement;

    var node = NodeLocator(offset).searchWithin(parsedUnit);

    var errorListener = RecordingErrorListener();

    return performance.run('resolve', (performance) {
      // TODO(scheglov): We don't need to do this for the whole unit.
      parsedUnit.accept(
        ResolutionVisitor(
          unitElement: unitElement,
          errorListener: errorListener,
          featureSet: _libraryElement.featureSet,
          nameScope: _libraryElement.scope,
          strictInference: _analysisOptions.strictInference,
          strictCasts: _analysisOptions.strictCasts,
          elementWalker: ElementWalker.forCompilationUnit(
            unitElement,
            libraryFilePath: _library.file.path,
            unitFilePath: file.path,
          ),
        ),
      );

      // TODO(scheglov): We don't need to do this for the whole unit.
      parsedUnit.accept(ScopeResolverVisitor(
          _libraryElement, file.source, _typeProvider, errorListener,
          nameScope: _libraryElement.scope));

      FlowAnalysisHelper flowAnalysisHelper = FlowAnalysisHelper(
          _testingData != null, _libraryElement.featureSet,
          typeSystemOperations: _typeSystemOperations);
      _testingData?.recordFlowAnalysisDataForTesting(
          file.uri, flowAnalysisHelper.dataForTesting!);

      var resolverVisitor = ResolverVisitor(_inheritance, _libraryElement,
          file.source, _typeProvider, errorListener,
          featureSet: _libraryElement.featureSet,
          analysisOptions: _library.file.analysisOptions,
          flowAnalysisHelper: flowAnalysisHelper);

      var nodeToResolve = node?.thisOrAncestorMatching((e) {
        return e.parent is ClassDeclaration ||
            e.parent is CompilationUnit ||
            e.parent is ExtensionDeclaration ||
            e.parent is MixinDeclaration;
      });
      if (nodeToResolve != null && nodeToResolve is! Directive) {
        var canResolveNode = resolverVisitor.prepareForResolving(nodeToResolve);
        if (canResolveNode) {
          nodeToResolve.accept(resolverVisitor);
          resolverVisitor.checkIdle();
          return AnalysisForCompletionResult(
            parsedUnit: parsedUnit,
            resolvedNodes: [nodeToResolve],
          );
        }
      }

      var units = _parseAndResolve();
      var unit = units[file]!;
      return AnalysisForCompletionResult(
        parsedUnit: unit,
        resolvedNodes: [unit],
      );
    });
  }

  void _checkForInconsistentLanguageVersionOverride(
    Map<FileState, CompilationUnit> units,
  ) {
    var libraryEntry = units.entries.first;
    var libraryUnit = libraryEntry.value;
    var libraryOverrideToken = libraryUnit.languageVersionToken;

    var elementToUnit = <CompilationUnitElement, CompilationUnit>{};
    for (var entry in units.entries) {
      var unit = entry.value;
      elementToUnit[unit.declaredElement!] = unit;
    }

    for (var directive in libraryUnit.directives) {
      if (directive is PartDirective) {
        final elementUri = directive.element?.uri;
        if (elementUri is DirectiveUriWithUnit) {
          final partUnit = elementToUnit[elementUri.unit];
          if (partUnit != null) {
            var shouldReport = false;
            var partOverrideToken = partUnit.languageVersionToken;
            if (libraryOverrideToken != null) {
              if (partOverrideToken != null) {
                if (partOverrideToken.major != libraryOverrideToken.major ||
                    partOverrideToken.minor != libraryOverrideToken.minor) {
                  shouldReport = true;
                }
              } else {
                shouldReport = true;
              }
            } else if (partOverrideToken != null) {
              shouldReport = true;
            }
            if (shouldReport) {
              _getErrorReporter(_library.file).reportErrorForNode(
                CompileTimeErrorCode.INCONSISTENT_LANGUAGE_VERSION_OVERRIDE,
                directive.uri,
              );
            }
          }
        }
      }
    }
  }

  void _computeConstantErrors(
      ErrorReporter errorReporter, FileState file, CompilationUnit unit) {
    ConstantVerifier constantVerifier = ConstantVerifier(
        errorReporter, _libraryElement, _declaredVariables,
        retainDataForTesting: _testingData != null);
    unit.accept(constantVerifier);
    _testingData?.recordExhaustivenessDataForTesting(
        file.uri, constantVerifier.exhaustivenessDataForTesting!);
  }

  /// Compute [_constants] in all units.
  void _computeConstants(Iterable<CompilationUnitImpl> units) {
    final configuration = ConstantEvaluationConfiguration();
    var constants = [
      for (var unit in units)
        ..._findConstants(
          unit: unit,
          configuration: configuration,
        ),
    ];
    computeConstants(
      declaredVariables: _declaredVariables,
      constants: constants,
      featureSet: _libraryElement.featureSet,
      configuration: configuration,
    );
  }

  /// Compute diagnostics in [units], including errors and warnings,
  /// lints, and a few other cases.
  void _computeDiagnostics(Map<FileState, CompilationUnitImpl> units) {
    units.forEach((file, unit) {
      _computeVerifyErrors(file, unit);
    });

    _libraryVerificationContext.constructorFieldsVerifier.report();

    if (_analysisOptions.warning) {
      var usedImportedElements = <UsedImportedElements>[];
      var usedLocalElements = <UsedLocalElements>[];
      for (var unit in units.values) {
        {
          var visitor = GatherUsedLocalElementsVisitor(_libraryElement);
          unit.accept(visitor);
          usedLocalElements.add(visitor.usedElements);
        }
        {
          var visitor = GatherUsedImportedElementsVisitor(_libraryElement);
          unit.accept(visitor);
          usedImportedElements.add(visitor.usedElements);
        }
      }
      var usedElements = UsedLocalElements.merge(usedLocalElements);
      units.forEach((file, unit) {
        _computeWarnings(
          file,
          unit,
          usedImportedElements: usedImportedElements,
          usedElements: usedElements,
        );
      });
    }

    if (_analysisOptions.lint) {
      final allUnits = _library.files
          .map((file) {
            final unit = units[file];
            if (unit != null) {
              return LinterContextUnit2(file, unit);
            } else {
              return null;
            }
          })
          .nonNulls
          .toList();
      for (final linterUnit in allUnits) {
        _computeLints(linterUnit.file, linterUnit, allUnits,
            analysisOptions: _analysisOptions);
      }
    }

    _checkForInconsistentLanguageVersionOverride(units);

    // This must happen after all other diagnostics have been computed but
    // before the list of diagnostics has been filtered.
    for (var file in _library.files) {
      final ignoreInfo = _fileToIgnoreInfo[file];
      // TODO(scheglov): make it safer
      if (ignoreInfo != null) {
        IgnoreValidator(
          _getErrorReporter(file),
          _getErrorListener(file).errors,
          ignoreInfo,
          _fileToLineInfo[file]!,
          _analysisOptions.unignorableNames,
        ).reportErrors();
      }
    }
  }

  void _computeLints(
    FileState file,
    LinterContextUnit currentUnit,
    List<LinterContextUnit> allUnits, {
    required AnalysisOptionsImpl analysisOptions,
  }) {
    var unit = currentUnit.unit;
    var errorReporter = _getErrorReporter(file);

    var enableTiming = analysisOptions.enableTiming;
    var nodeRegistry = NodeLintRegistry(enableTiming);

    var context = LinterContextImpl(
      allUnits,
      currentUnit,
      _declaredVariables,
      _typeProvider,
      _typeSystem,
      _inheritance,
      analysisOptions,
      file.workspacePackage,
      _pathContext,
    );
    for (var linter in analysisOptions.lintRules) {
      linter.reporter = errorReporter;
      var timer = enableTiming ? lintRegistry.getTimer(linter) : null;
      timer?.start();
      linter.registerNodeProcessors(nodeRegistry, context);
      timer?.stop();
    }

    // Run lints that handle specific node types.
    unit.accept(
      LinterVisitor(
        nodeRegistry,
        LinterExceptionHandler(
          propagateExceptions: analysisOptions.propagateLinterExceptions,
        ).logException,
      ),
    );
  }

  void _computeVerifyErrors(FileState file, CompilationUnit unit) {
    ErrorReporter errorReporter = _getErrorReporter(file);

    if (!unit.featureSet.isEnabled(Feature.non_nullable)) {
      CodeChecker checker = CodeChecker(
        _typeProvider,
        _typeSystem,
        errorReporter,
        strictCasts: _analysisOptions.strictCasts,
      );
      checker.visitCompilationUnit(unit);
    }

    //
    // Use the ConstantVerifier to compute errors.
    //
    _computeConstantErrors(errorReporter, file, unit);

    //
    // Compute inheritance and override errors.
    //
    var inheritanceOverrideVerifier = InheritanceOverrideVerifier(
        _typeSystem, _inheritance, errorReporter,
        strictCasts: _analysisOptions.strictCasts);
    inheritanceOverrideVerifier.verifyUnit(unit);

    //
    // Use the ErrorVerifier to compute errors.
    //
    ErrorVerifier errorVerifier = ErrorVerifier(
      errorReporter,
      _libraryElement,
      _typeProvider,
      _inheritance,
      _libraryVerificationContext,
      _analysisOptions,
      typeSystemOperations: _typeSystemOperations,
    );
    unit.accept(errorVerifier);

    // Verify constraints on FFI uses. The CFE enforces these constraints as
    // compile-time errors and so does the analyzer.
    unit.accept(FfiVerifier(_typeSystem, errorReporter,
        strictCasts: _analysisOptions.strictCasts));
  }

  void _computeWarnings(
    FileState file,
    CompilationUnit unit, {
    required List<UsedImportedElements> usedImportedElements,
    required UsedLocalElements usedElements,
  }) {
    AnalysisErrorListener errorListener = _getErrorListener(file);
    ErrorReporter errorReporter = _getErrorReporter(file);

    UnicodeTextVerifier(errorReporter).verify(unit, file.content);

    unit.accept(DeadCodeVerifier(errorReporter));

    unit.accept(
      BestPracticesVerifier(
        errorReporter,
        _typeProvider,
        _libraryElement,
        unit,
        file.content,
        declaredVariables: _declaredVariables,
        typeSystem: _typeSystem,
        inheritanceManager: _inheritance,
        analysisOptions: _analysisOptions,
        workspacePackage: _library.file.workspacePackage,
        pathContext: _pathContext,
      ),
    );

    unit.accept(OverrideVerifier(
      _inheritance,
      _libraryElement,
      errorReporter,
    ));

    unit.accept(RedeclareVerifier(
      _inheritance,
      _libraryElement,
      errorReporter,
    ));

    TodoFinder(errorReporter).findIn(unit);
    LanguageVersionOverrideVerifier(errorReporter).verify(unit);

    // Verify imports.
    {
      ImportsVerifier verifier = ImportsVerifier();
      verifier.addImports(unit);
      usedImportedElements.forEach(verifier.removeUsedElements);
      verifier.generateDuplicateExportWarnings(errorReporter);
      verifier.generateDuplicateImportWarnings(errorReporter);
      verifier.generateDuplicateShownHiddenNameWarnings(errorReporter);
      verifier.generateUnusedImportHints(errorReporter);
      verifier.generateUnusedShownNameHints(errorReporter);
      verifier.generateUnnecessaryImportHints(
          errorReporter, usedImportedElements);
    }

    // Unused local elements.
    {
      UnusedLocalElementsVerifier visitor = UnusedLocalElementsVerifier(
          errorListener, usedElements, _inheritance, _libraryElement);
      unit.accept(visitor);
    }

    //
    // Find code that uses features from an SDK version that does not satisfy
    // the SDK constraints specified in analysis options.
    //
    var package = file.workspacePackage;
    var sdkVersionConstraint =
        (package is PubWorkspacePackage) ? package.sdkVersionConstraint : null;
    if (sdkVersionConstraint != null) {
      SdkConstraintVerifier verifier = SdkConstraintVerifier(
        errorReporter,
        _libraryElement,
        _typeProvider,
        sdkVersionConstraint.withoutPreRelease,
      );
      unit.accept(verifier);
    }
  }

  /// Return a subset of the given [errors] that are not marked as ignored in
  /// the [file].
  List<AnalysisError> _filterIgnoredErrors(
      FileState file, List<AnalysisError> errors) {
    if (errors.isEmpty) {
      return errors;
    }

    IgnoreInfo ignoreInfo = _fileToIgnoreInfo[file]!;
    if (!ignoreInfo.hasIgnores) {
      return errors;
    }

    var unignorableCodes = _analysisOptions.unignorableNames;

    bool isIgnored(AnalysisError error) {
      var code = error.errorCode;
      // Don't allow un-ignorable codes to be ignored.
      if (unignorableCodes.contains(code.name) ||
          unignorableCodes.contains(code.uniqueName) ||
          // Lint rules have lower case names.
          unignorableCodes.contains(code.name.toUpperCase())) {
        return false;
      }
      return ignoreInfo.ignored(error);
    }

    return errors.where((AnalysisError e) => !isIgnored(e)).toList();
  }

  /// Find constants in [unit] to compute.
  List<ConstantEvaluationTarget> _findConstants({
    required CompilationUnit unit,
    required ConstantEvaluationConfiguration configuration,
  }) {
    ConstantFinder constantFinder = ConstantFinder(
      configuration: configuration,
    );
    unit.accept(constantFinder);

    var dependenciesFinder = ConstantExpressionsDependenciesFinder();
    unit.accept(dependenciesFinder);
    return [
      ...constantFinder.constantsToCompute,
      ...dependenciesFinder.dependencies,
    ];
  }

  RecordingErrorListener _getErrorListener(FileState file) =>
      _errorListeners.putIfAbsent(file, () => RecordingErrorListener());

  ErrorReporter _getErrorReporter(FileState file) {
    return _errorReporters.putIfAbsent(file, () {
      RecordingErrorListener listener = _getErrorListener(file);
      return ErrorReporter(
        listener,
        file.source,
        isNonNullableByDefault: _libraryElement.isNonNullableByDefault,
      );
    });
  }

  /// Return a new parsed unresolved [CompilationUnit].
  CompilationUnitImpl _parse(FileState file) {
    AnalysisErrorListener errorListener = _getErrorListener(file);
    String content = file.content;
    var unit = file.parse(errorListener);

    // TODO(scheglov): Store [IgnoreInfo] as unlinked data.
    _fileToLineInfo[file] = unit.lineInfo;
    _fileToIgnoreInfo[file] = IgnoreInfo.forDart(unit, content);

    return unit;
  }

  /// Parse and resolve all files in [_library].
  Map<FileState, CompilationUnitImpl> _parseAndResolve() {
    final units = <FileState, CompilationUnitImpl>{};
    _resolveDirectives(
      containerKind: _library,
      containerElement: _libraryElement,
      units: units,
    );

    units.forEach((file, unit) {
      _resolveFile(file, unit);
    });

    _computeConstants(units.values);

    return units;
  }

  void _resolveAugmentationImportDirective({
    required AugmentationImportDirectiveImpl? directive,
    required AugmentationImportElementImpl element,
    required AugmentationImportState state,
    required ErrorReporter errorReporter,
    required Set<AugmentationFileKind> seenAugmentations,
    required Map<FileState, CompilationUnitImpl> units,
  }) {
    directive?.element = element;

    void reportOnDirective(ErrorCode errorCode, List<Object>? arguments) {
      if (directive != null) {
        errorReporter.reportErrorForNode(errorCode, directive.uri, arguments);
      }
    }

    final AugmentationFileKind? importedAugmentationKind;
    if (state is AugmentationImportWithFile) {
      importedAugmentationKind = state.importedAugmentation;
      if (!state.importedFile.exists) {
        reportOnDirective(
          isGeneratedSource(state.importedSource)
              ? CompileTimeErrorCode.URI_HAS_NOT_BEEN_GENERATED
              : CompileTimeErrorCode.URI_DOES_NOT_EXIST,
          [state.importedFile.uriStr],
        );
        return;
      } else if (importedAugmentationKind == null) {
        reportOnDirective(
          CompileTimeErrorCode.IMPORT_OF_NOT_AUGMENTATION,
          [state.importedFile.uriStr],
        );
        return;
      } else if (!seenAugmentations.add(importedAugmentationKind)) {
        reportOnDirective(
          CompileTimeErrorCode.DUPLICATE_AUGMENTATION_IMPORT,
          [state.importedFile.uriStr],
        );
        return;
      }
    } else if (state is AugmentationImportWithUri) {
      reportOnDirective(
        CompileTimeErrorCode.URI_DOES_NOT_EXIST,
        [state.uri.relativeUriStr],
      );
      return;
    } else if (state is AugmentationImportWithUriStr) {
      reportOnDirective(
        CompileTimeErrorCode.INVALID_URI,
        [state.uri.relativeUriStr],
      );
      return;
    } else {
      reportOnDirective(
        CompileTimeErrorCode.URI_WITH_INTERPOLATION,
        null,
      );
      return;
    }

    final augmentationFile = importedAugmentationKind.file;
    final augmentationUnit = _parse(augmentationFile);
    units[augmentationFile] = augmentationUnit;

    final importedAugmentation = element.importedAugmentation!;
    augmentationUnit.declaredElement =
        importedAugmentation.definingCompilationUnit;

    for (final directive in augmentationUnit.directives) {
      if (directive is AugmentationImportDirectiveImpl) {
        directive.element = importedAugmentation;
      }
    }

    _resolveDirectives(
      containerKind: importedAugmentationKind,
      containerElement: importedAugmentation,
      units: units,
    );
  }

  /// Parses the file of [containerKind], and resolves directives.
  /// Recursively parses augmentations and parts.
  void _resolveDirectives({
    required LibraryOrAugmentationFileKind containerKind,
    required LibraryOrAugmentationElementImpl containerElement,
    required Map<FileState, CompilationUnitImpl> units,
  }) {
    final containerFile = containerKind.file;
    final containerUnit = _parse(containerFile);
    containerUnit.declaredElement = containerElement.definingCompilationUnit;
    units[containerFile] = containerUnit;

    final containerErrorReporter = _getErrorReporter(containerFile);

    var augmentationImportIndex = 0;
    var libraryExportIndex = 0;
    var libraryImportIndex = 0;
    var partIndex = 0;

    LibraryIdentifier? libraryNameNode;
    final seenAugmentations = <AugmentationFileKind>{};
    final seenPartSources = <Source>{};
    for (Directive directive in containerUnit.directives) {
      if (directive is AugmentationImportDirectiveImpl) {
        final index = augmentationImportIndex++;
        _resolveAugmentationImportDirective(
          directive: directive,
          element: containerElement.augmentationImports[index],
          state: containerKind.augmentationImports[index],
          errorReporter: containerErrorReporter,
          seenAugmentations: seenAugmentations,
          units: units,
        );
      } else if (directive is ExportDirectiveImpl) {
        final index = libraryExportIndex++;
        _resolveLibraryExportDirective(
          directive: directive,
          element: containerElement.libraryExports[index],
          state: containerKind.libraryExports[index],
          errorReporter: containerErrorReporter,
        );
      } else if (directive is ImportDirectiveImpl) {
        final index = libraryImportIndex++;
        _resolveLibraryImportDirective(
          directive: directive,
          element: containerElement.libraryImports[index],
          state: containerKind.libraryImports[index],
          errorReporter: containerErrorReporter,
        );
      } else if (directive is LibraryAugmentationDirectiveImpl) {
        _resolveLibraryAugmentationDirective(
          directive: directive,
          containerKind: containerKind,
          containerElement: containerElement,
          containerErrorReporter: containerErrorReporter,
        );
      } else if (directive is LibraryDirectiveImpl) {
        directive.element = containerElement;
        libraryNameNode = directive.name2;
      } else if (directive is PartDirectiveImpl) {
        if (containerKind is LibraryFileKind &&
            containerElement is LibraryElementImpl) {
          final index = partIndex++;
          _resolvePartDirective(
            directive: directive,
            partState: containerKind.parts[index],
            partElement: containerElement.parts[index],
            errorReporter: containerErrorReporter,
            libraryNameNode: libraryNameNode,
            units: units,
            seenPartSources: seenPartSources,
          );
        }
      }
    }

    // The macro augmentation does not have an explicit `import` directive.
    // So, we look into the file augmentation imports.
    final macroImport = containerKind.augmentationImports.lastOrNull;
    if (macroImport is AugmentationImportWithFile) {
      final importedFile = macroImport.importedFile;
      if (importedFile.isMacroAugmentation) {
        _resolveAugmentationImportDirective(
          directive: null,
          element: _libraryElement.augmentationImports.last,
          state: macroImport,
          errorReporter: containerErrorReporter,
          seenAugmentations: seenAugmentations,
          units: units,
        );
      }
    }
  }

  void _resolveFile(FileState file, CompilationUnitImpl unit) {
    var source = file.source;
    var errorListener = _getErrorListener(file);

    var unitElement = unit.declaredElement!;

    unit.accept(
      ResolutionVisitor(
        unitElement: unitElement,
        errorListener: errorListener,
        featureSet: unit.featureSet,
        nameScope: unitElement.enclosingElement.scope,
        strictInference: _analysisOptions.strictInference,
        strictCasts: _analysisOptions.strictCasts,
        elementWalker: ElementWalker.forCompilationUnit(
          unitElement,
          libraryFilePath: _library.file.path,
          unitFilePath: file.path,
        ),
      ),
    );

    unit.accept(ScopeResolverVisitor(
        _libraryElement, source, _typeProvider, errorListener,
        nameScope: unitElement.enclosingElement.scope));

    // Nothing for RESOLVED_UNIT8?
    // Nothing for RESOLVED_UNIT9?
    // Nothing for RESOLVED_UNIT10?

    FlowAnalysisHelper flowAnalysisHelper = FlowAnalysisHelper(
        _testingData != null, unit.featureSet,
        typeSystemOperations: _typeSystemOperations);
    _testingData?.recordFlowAnalysisDataForTesting(
        file.uri, flowAnalysisHelper.dataForTesting!);

    unit.accept(ResolverVisitor(
        _inheritance, _libraryElement, source, _typeProvider, errorListener,
        analysisOptions: _library.file.analysisOptions,
        featureSet: unit.featureSet,
        flowAnalysisHelper: flowAnalysisHelper));
  }

  void _resolveLibraryAugmentationDirective({
    required LibraryAugmentationDirectiveImpl directive,
    required LibraryOrAugmentationFileKind containerKind,
    required LibraryOrAugmentationElementImpl containerElement,
    required ErrorReporter containerErrorReporter,
  }) {
    directive.element = containerElement;

    // If we had to treat this augmentation as a library.
    if (containerKind is! LibraryFileKind) {
      return;
    }

    // We should recover from an augmentation.
    final recoveredFrom = containerKind.recoveredFrom;
    if (recoveredFrom is! AugmentationFileKind) {
      return;
    }

    final targetUri = recoveredFrom.uri;
    if (targetUri is DirectiveUriWithFile) {
      final targetFile = targetUri.file;
      if (!targetFile.exists) {
        containerErrorReporter.reportErrorForNode(
          CompileTimeErrorCode.URI_DOES_NOT_EXIST,
          directive.uri,
          [targetUri.relativeUriStr],
        );
        return;
      }

      final targetFileKind = targetFile.kind;
      if (targetFileKind is LibraryFileKind) {
        containerErrorReporter.reportErrorForNode(
          CompileTimeErrorCode.AUGMENTATION_WITHOUT_IMPORT,
          directive.uri,
        );
        return;
      }
    }

    // Otherwise, there are many other problems with the URI.
    containerErrorReporter.reportErrorForNode(
      CompileTimeErrorCode.AUGMENTATION_WITHOUT_LIBRARY,
      directive.uri,
    );
  }

  void _resolveLibraryExportDirective({
    required ExportDirectiveImpl directive,
    required LibraryExportElement element,
    required LibraryExportState state,
    required ErrorReporter errorReporter,
  }) {
    directive.element = element;
    _resolveNamespaceDirective(
      directive: directive,
      primaryUriNode: directive.uri,
      primaryUriState: state.uris.primary,
      configurationNodes: directive.configurations,
      configurationUris: state.uris.configurations,
      selectedUriState: state.selectedUri,
    );
    if (state is LibraryExportWithUri) {
      final selectedUriStr = state.selectedUri.relativeUriStr;
      if (selectedUriStr.startsWith('dart-ext:')) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.USE_OF_NATIVE_EXTENSION,
          directive.uri,
        );
      } else if (state.exportedSource == null) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.URI_DOES_NOT_EXIST,
          directive.uri,
          [selectedUriStr],
        );
      } else if (state is LibraryExportWithFile && !state.exportedFile.exists) {
        final errorCode = isGeneratedSource(state.exportedSource)
            ? CompileTimeErrorCode.URI_HAS_NOT_BEEN_GENERATED
            : CompileTimeErrorCode.URI_DOES_NOT_EXIST;
        errorReporter.reportErrorForNode(
          errorCode,
          directive.uri,
          [selectedUriStr],
        );
      } else if (state.exportedLibrarySource == null) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.EXPORT_OF_NON_LIBRARY,
          directive.uri,
          [selectedUriStr],
        );
      }
    } else if (state is LibraryExportWithUriStr) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.INVALID_URI,
        directive.uri,
        [state.selectedUri.relativeUriStr],
      );
    } else {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.URI_WITH_INTERPOLATION,
        directive.uri,
      );
    }
  }

  void _resolveLibraryImportDirective({
    required ImportDirectiveImpl directive,
    required LibraryImportElement element,
    required LibraryImportState state,
    required ErrorReporter errorReporter,
  }) {
    directive.element = element;
    directive.prefix?.staticElement = element.prefix?.element;
    _resolveNamespaceDirective(
      directive: directive,
      primaryUriNode: directive.uri,
      primaryUriState: state.uris.primary,
      configurationNodes: directive.configurations,
      configurationUris: state.uris.configurations,
      selectedUriState: state.selectedUri,
    );
    if (state is LibraryImportWithUri) {
      final selectedUriStr = state.selectedUri.relativeUriStr;
      if (selectedUriStr.startsWith('dart-ext:')) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.USE_OF_NATIVE_EXTENSION,
          directive.uri,
        );
      } else if (state.importedSource == null) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.URI_DOES_NOT_EXIST,
          directive.uri,
          [selectedUriStr],
        );
      } else if (state is LibraryImportWithFile && !state.importedFile.exists) {
        final errorCode = isGeneratedSource(state.importedSource)
            ? CompileTimeErrorCode.URI_HAS_NOT_BEEN_GENERATED
            : CompileTimeErrorCode.URI_DOES_NOT_EXIST;
        errorReporter.reportErrorForNode(
          errorCode,
          directive.uri,
          [selectedUriStr],
        );
      } else if (state.importedLibrarySource == null) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.IMPORT_OF_NON_LIBRARY,
          directive.uri,
          [selectedUriStr],
        );
      }
    } else if (state is LibraryImportWithUriStr) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.INVALID_URI,
        directive.uri,
        [state.selectedUri.relativeUriStr],
      );
    } else {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.URI_WITH_INTERPOLATION,
        directive.uri,
      );
    }
  }

  void _resolveNamespaceDirective({
    required NamespaceDirectiveImpl directive,
    required StringLiteralImpl primaryUriNode,
    required file_state.DirectiveUri primaryUriState,
    required file_state.DirectiveUri selectedUriState,
    required List<Configuration> configurationNodes,
    required List<file_state.DirectiveUri> configurationUris,
  }) {
    for (var i = 0; i < configurationNodes.length; i++) {
      final node = configurationNodes[i] as ConfigurationImpl;
      node.resolvedUri = configurationUris[i].asDirectiveUri;
    }
  }

  void _resolvePartDirective({
    required PartDirectiveImpl directive,
    required PartState partState,
    required PartElement partElement,
    required ErrorReporter errorReporter,
    required LibraryIdentifier? libraryNameNode,
    required Map<FileState, CompilationUnitImpl> units,
    required Set<Source> seenPartSources,
  }) {
    StringLiteral partUri = directive.uri;

    directive.element = partElement;

    if (partState is! PartWithUriStr) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.URI_WITH_INTERPOLATION,
        directive.uri,
      );
      return;
    }

    if (partState is! PartWithUri) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.INVALID_URI,
        directive.uri,
        [partState.uri.relativeUriStr],
      );
      return;
    }

    if (partState is! PartWithFile) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.URI_DOES_NOT_EXIST,
        directive.uri,
        [partState.uri.relativeUriStr],
      );
      return;
    }

    final includedFile = partState.includedFile;
    final includedKind = includedFile.kind;

    if (includedKind is! PartFileKind) {
      final ErrorCode errorCode;
      if (includedFile.exists) {
        errorCode = CompileTimeErrorCode.PART_OF_NON_PART;
      } else if (isGeneratedSource(includedFile.source)) {
        errorCode = CompileTimeErrorCode.URI_HAS_NOT_BEEN_GENERATED;
      } else {
        errorCode = CompileTimeErrorCode.URI_DOES_NOT_EXIST;
      }
      errorReporter.reportErrorForNode(
        errorCode,
        partUri,
        [includedFile.uriStr],
      );
      return;
    }

    if (includedKind is PartOfNameFileKind) {
      if (!includedKind.libraries.contains(_library)) {
        final name = includedKind.unlinked.name;
        if (libraryNameNode == null) {
          errorReporter.reportErrorForNode(
            CompileTimeErrorCode.PART_OF_UNNAMED_LIBRARY,
            partUri,
            [name],
          );
        } else {
          errorReporter.reportErrorForNode(
            CompileTimeErrorCode.PART_OF_DIFFERENT_LIBRARY,
            partUri,
            [libraryNameNode.name, name],
          );
        }
        return;
      }
    } else if (includedKind.library != _library) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.PART_OF_DIFFERENT_LIBRARY,
        partUri,
        [_library.file.uriStr, includedFile.uriStr],
      );
      return;
    }

    final partUnit = _parse(includedFile);
    units[includedFile] = partUnit;

    final partElementUri = partElement.uri;
    if (partElementUri is DirectiveUriWithUnitImpl) {
      partUnit.declaredElement = partElementUri.unit;
    }

    final partSource = includedKind.file.source;

    for (final directive in partUnit.directives) {
      if (directive is PartOfDirectiveImpl) {
        directive.element = _libraryElement;
      }
    }

    //
    // Validate that the part source is unique in the library.
    //
    if (!seenPartSources.add(partSource)) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.DUPLICATE_PART, partUri, [partSource.uri]);
    }
  }
}

/// Analysis result for single file.
class UnitAnalysisResult {
  final FileState file;
  final CompilationUnit unit;
  final List<AnalysisError> errors;

  UnitAnalysisResult(this.file, this.unit, this.errors);
}

extension on file_state.DirectiveUri {
  DirectiveUriImpl get asDirectiveUri {
    final self = this;
    if (self is file_state.DirectiveUriWithSource) {
      return DirectiveUriWithSourceImpl(
        relativeUriString: self.relativeUriStr,
        relativeUri: self.relativeUri,
        source: self.source,
      );
    } else if (self is file_state.DirectiveUriWithUri) {
      return DirectiveUriWithRelativeUriImpl(
        relativeUriString: self.relativeUriStr,
        relativeUri: self.relativeUri,
      );
    } else if (self is file_state.DirectiveUriWithString) {
      return DirectiveUriWithRelativeUriStringImpl(
        relativeUriString: self.relativeUriStr,
      );
    }
    return DirectiveUriImpl();
  }
}
