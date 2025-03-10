private import codeql.ssa.Ssa as SsaImplCommon
private import semmle.code.cpp.ir.IR
private import DataFlowUtil
private import DataFlowImplCommon as DataFlowImplCommon
private import semmle.code.cpp.models.interfaces.Allocation as Alloc
private import semmle.code.cpp.models.interfaces.DataFlow as DataFlow
private import semmle.code.cpp.models.interfaces.Taint as Taint
private import semmle.code.cpp.models.interfaces.PartialFlow as PartialFlow
private import semmle.code.cpp.models.interfaces.FunctionInputsAndOutputs as FIO
private import semmle.code.cpp.ir.internal.IRCppLanguage
private import semmle.code.cpp.ir.dataflow.internal.ModelUtil
private import DataFlowPrivate
import SsaInternalsCommon

private module SourceVariables {
  cached
  private newtype TSourceVariable =
    TMkSourceVariable(BaseSourceVariable base, int ind) {
      ind = [0 .. countIndirectionsForCppType(base.getLanguageType()) + 1]
    }

  private int maxNumberOfIndirections() { result = max(SourceVariable sv | | sv.getIndirection()) }

  private string repeatStars(int n) {
    n = 0 and result = ""
    or
    n = [1 .. maxNumberOfIndirections()] and
    result = "*" + repeatStars(n - 1)
  }

  class SourceVariable extends TSourceVariable {
    BaseSourceVariable base;
    int ind;

    SourceVariable() { this = TMkSourceVariable(base, ind) }

    /** Gets the IR variable associated with this `SourceVariable`, if any. */
    IRVariable getIRVariable() { result = base.(BaseIRVariable).getIRVariable() }

    /**
     * Gets the base source variable (i.e., the variable without any
     * indirections) of this source variable.
     */
    BaseSourceVariable getBaseVariable() { result = base }

    /** Gets a textual representation of this element. */
    string toString() { result = repeatStars(this.getIndirection()) + base.toString() }

    /**
     * Gets the number of loads performed on the base source variable
     * to reach the value of this source variable.
     */
    int getIndirection() { result = ind }

    /** Holds if this variable is a glvalue. */
    predicate isGLValue() { ind = 0 }

    /**
     * Gets the type of this source variable. If `isGLValue()` holds, then
     * the type of this source variable should be thought of as "pointer
     * to `getType()`".
     */
    DataFlowType getType() {
      if this.isGLValue()
      then result = base.getType()
      else result = getTypeImpl(base.getType(), ind - 1)
    }

    /** Gets the location of this variable. */
    Location getLocation() { result = this.getBaseVariable().getLocation() }
  }
}

import SourceVariables

/**
 * Holds if the `(operand, indirectionIndex)` columns should be
 * assigned a `RawIndirectOperand` value.
 */
predicate hasRawIndirectOperand(Operand op, int indirectionIndex) {
  exists(CppType type, int m |
    not ignoreOperand(op) and
    type = getLanguageType(op) and
    m = countIndirectionsForCppType(type) and
    indirectionIndex = [1 .. m] and
    not hasIRRepresentationOfIndirectOperand(op, indirectionIndex, _, _)
  )
}

/**
 * Holds if the `(instr, indirectionIndex)` columns should be
 * assigned a `RawIndirectInstruction` value.
 */
predicate hasRawIndirectInstruction(Instruction instr, int indirectionIndex) {
  exists(CppType type, int m |
    not ignoreInstruction(instr) and
    type = getResultLanguageType(instr) and
    m = countIndirectionsForCppType(type) and
    indirectionIndex = [1 .. m] and
    not hasIRRepresentationOfIndirectInstruction(instr, indirectionIndex, _, _)
  )
}

cached
private newtype TDefOrUseImpl =
  TDefImpl(BaseSourceVariableInstruction base, Operand address, int indirectionIndex) {
    isDef(_, _, address, base, _, indirectionIndex)
  } or
  TUseImpl(BaseSourceVariableInstruction base, Operand operand, int indirectionIndex) {
    isUse(_, operand, base, _, indirectionIndex) and
    not isDef(true, _, operand, _, _, _)
  } or
  TGlobalUse(GlobalLikeVariable v, IRFunction f, int indirectionIndex) {
    // Represents a final "use" of a global variable to ensure that
    // the assignment to a global variable isn't ruled out as dead.
    isGlobalUse(v, f, _, indirectionIndex)
  } or
  TGlobalDefImpl(GlobalLikeVariable v, IRFunction f, int indirectionIndex) {
    // Represents the initial "definition" of a global variable when entering
    // a function body.
    isGlobalDefImpl(v, f, _, indirectionIndex)
  } or
  TIteratorDef(
    Operand iteratorDerefAddress, BaseSourceVariableInstruction container, int indirectionIndex
  ) {
    isIteratorDef(container, iteratorDerefAddress, _, _, indirectionIndex)
  } or
  TIteratorUse(
    Operand iteratorAddress, BaseSourceVariableInstruction container, int indirectionIndex
  ) {
    isIteratorUse(container, iteratorAddress, _, indirectionIndex)
  } or
  TFinalParameterUse(Parameter p, int indirectionIndex) {
    underlyingTypeIsModifiableAt(p.getUnderlyingType(), indirectionIndex) and
    // Only create an SSA read for the final use of a parameter if there's
    // actually a body of the enclosing function. If there's no function body
    // then we'll never need to flow out of the function anyway.
    p.getFunction().hasDefinition()
  }

private predicate isGlobalUse(
  GlobalLikeVariable v, IRFunction f, int indirection, int indirectionIndex
) {
  // Generate a "global use" at the end of the function body if there's a
  // direct definition somewhere in the body of the function
  indirection =
    min(int cand, VariableAddressInstruction vai |
      vai.getEnclosingIRFunction() = f and
      vai.getAstVariable() = v and
      isDef(_, _, _, vai, cand, indirectionIndex)
    |
      cand
    )
}

private predicate isGlobalDefImpl(
  GlobalLikeVariable v, IRFunction f, int indirection, int indirectionIndex
) {
  exists(VariableAddressInstruction vai |
    vai.getEnclosingIRFunction() = f and
    vai.getAstVariable() = v and
    isUse(_, _, vai, indirection, indirectionIndex) and
    not isDef(_, _, _, vai, _, indirectionIndex)
  )
}

private predicate underlyingTypeIsModifiableAt(Type underlying, int indirectionIndex) {
  indirectionIndex =
    [1 .. getIndirectionForUnspecifiedType(underlying.getUnspecifiedType())
          .getNumberOfIndirections()] and
  exists(CppType cppType |
    cppType.hasUnderlyingType(underlying, false) and
    isModifiableAt(cppType, indirectionIndex)
  )
}

private Indirection getIndirectionForUnspecifiedType(Type t) { result.getType() = t }

abstract private class DefOrUseImpl extends TDefOrUseImpl {
  /** Gets a textual representation of this element. */
  abstract string toString();

  /** Gets the block of this definition or use. */
  final IRBlock getBlock() { this.hasIndexInBlock(result, _) }

  /** Holds if this definition or use has index `index` in block `block`. */
  abstract predicate hasIndexInBlock(IRBlock block, int index);

  /**
   * Holds if this definition (or use) has index `index` in block `block`,
   * and is a definition (or use) of the variable `sv`
   */
  final predicate hasIndexInBlock(IRBlock block, int index, SourceVariable sv) {
    this.hasIndexInBlock(block, index) and
    sv = this.getSourceVariable()
  }

  /** Gets the location of this element. */
  abstract Cpp::Location getLocation();

  /**
   * Gets the index (i.e., the number of loads required) of this
   * definition or use.
   *
   * Note that this is _not_ the definition's (or use's) index in
   * the enclosing basic block. To obtain this index, use
   * `DefOrUseImpl::hasIndexInBlock/2` or `DefOrUseImpl::hasIndexInBlock/3`.
   */
  abstract int getIndirectionIndex();

  /**
   * Gets the instruction that computes the base of this definition or use.
   * This is always a `VariableAddressInstruction` or an `CallInstruction`.
   */
  abstract BaseSourceVariableInstruction getBase();

  /**
   * Gets the base source variable (i.e., the variable without
   * any indirection) of this definition or use.
   */
  final BaseSourceVariable getBaseSourceVariable() {
    this.getBase().getBaseSourceVariable() = result
  }

  /** Gets the variable that is defined or used. */
  SourceVariable getSourceVariable() {
    exists(BaseSourceVariable v, int ind |
      sourceVariableHasBaseAndIndex(result, v, ind) and
      defOrUseHasSourceVariable(this, v, ind)
    )
  }
}

private predicate defOrUseHasSourceVariable(DefOrUseImpl defOrUse, BaseSourceVariable bv, int ind) {
  defHasSourceVariable(defOrUse, bv, ind)
  or
  useHasSourceVariable(defOrUse, bv, ind)
}

pragma[noinline]
private predicate defHasSourceVariable(DefImpl def, BaseSourceVariable bv, int ind) {
  bv = def.getBaseSourceVariable() and
  ind = def.getIndirection()
}

pragma[noinline]
private predicate useHasSourceVariable(UseImpl use, BaseSourceVariable bv, int ind) {
  bv = use.getBaseSourceVariable() and
  ind = use.getIndirection()
}

pragma[noinline]
private predicate sourceVariableHasBaseAndIndex(SourceVariable v, BaseSourceVariable bv, int ind) {
  v.getBaseVariable() = bv and
  v.getIndirection() = ind
}

abstract class DefImpl extends DefOrUseImpl {
  Operand address;
  int ind;

  bindingset[ind]
  DefImpl() { any() }

  abstract int getIndirection();

  abstract Node0Impl getValue();

  abstract predicate isCertain();

  Operand getAddressOperand() { result = address }

  override int getIndirectionIndex() { result = ind }

  override string toString() { result = "Def of " + this.getSourceVariable() }

  override Cpp::Location getLocation() { result = this.getAddressOperand().getUse().getLocation() }

  final override predicate hasIndexInBlock(IRBlock block, int index) {
    this.getAddressOperand().getUse() = block.getInstruction(index)
  }
}

private class DirectDef extends DefImpl, TDefImpl {
  BaseSourceVariableInstruction base;

  DirectDef() { this = TDefImpl(base, address, ind) }

  override BaseSourceVariableInstruction getBase() { result = base }

  override int getIndirection() { isDef(_, _, address, base, result, ind) }

  override Node0Impl getValue() { isDef(_, result, address, base, _, _) }

  override predicate isCertain() { isDef(true, _, address, base, _, ind) }
}

private class IteratorDef extends DefImpl, TIteratorDef {
  BaseSourceVariableInstruction container;

  IteratorDef() { this = TIteratorDef(address, container, ind) }

  override BaseSourceVariableInstruction getBase() { result = container }

  override int getIndirection() { isIteratorDef(container, address, _, result, ind) }

  override Node0Impl getValue() { isIteratorDef(container, address, result, _, _) }

  override predicate isCertain() { none() }
}

abstract class UseImpl extends DefOrUseImpl {
  int ind;

  bindingset[ind]
  UseImpl() { any() }

  /** Gets the node associated with this use. */
  abstract Node getNode();

  override string toString() { result = "Use of " + this.getSourceVariable() }

  /** Gets the indirection index of this use. */
  final override int getIndirectionIndex() { result = ind }

  /** Gets the number of loads that precedence this use. */
  abstract int getIndirection();

  /**
   * Holds if this use is guaranteed to read the
   * associated variable.
   */
  abstract predicate isCertain();
}

abstract private class OperandBasedUse extends UseImpl {
  Operand operand;
  BaseSourceVariableInstruction base;

  bindingset[ind]
  OperandBasedUse() { any() }

  final override predicate hasIndexInBlock(IRBlock block, int index) {
    // See the comment in `ssa0`'s `OperandBasedUse` for an explanation of this
    // predicate's implementation.
    if base.getAst() = any(Cpp::PostfixCrementOperation c).getOperand()
    then
      exists(Operand op, int indirectionIndex, int indirection |
        indirectionIndex = this.getIndirectionIndex() and
        indirection = this.getIndirection() and
        op =
          min(Operand cand, int i |
            isUse(_, cand, base, indirection, indirectionIndex) and
            block.getInstruction(i) = cand.getUse()
          |
            cand order by i
          ) and
        block.getInstruction(index) = op.getUse()
      )
    else operand.getUse() = block.getInstruction(index)
  }

  final override BaseSourceVariableInstruction getBase() { result = base }

  final Operand getOperand() { result = operand }

  final override Cpp::Location getLocation() { result = operand.getLocation() }
}

private class DirectUse extends OperandBasedUse, TUseImpl {
  DirectUse() { this = TUseImpl(base, operand, ind) }

  override int getIndirection() { isUse(_, operand, base, result, ind) }

  override predicate isCertain() { isUse(true, operand, base, _, ind) }

  override Node getNode() { nodeHasOperand(result, operand, ind) }
}

private class IteratorUse extends OperandBasedUse, TIteratorUse {
  IteratorUse() { this = TIteratorUse(operand, base, ind) }

  override int getIndirection() { isIteratorUse(base, operand, result, ind) }

  override predicate isCertain() { none() }

  override Node getNode() { nodeHasOperand(result, operand, ind) }
}

pragma[nomagic]
private predicate finalParameterNodeHasParameterAndIndex(
  FinalParameterNode n, Parameter p, int indirectionIndex
) {
  n.getParameter() = p and
  n.getIndirectionIndex() = indirectionIndex
}

class FinalParameterUse extends UseImpl, TFinalParameterUse {
  Parameter p;

  FinalParameterUse() { this = TFinalParameterUse(p, ind) }

  Parameter getParameter() { result = p }

  override Node getNode() { finalParameterNodeHasParameterAndIndex(result, p, ind) }

  override int getIndirection() { result = ind + 1 }

  override predicate isCertain() { any() }

  override predicate hasIndexInBlock(IRBlock block, int index) {
    // Ideally, this should always be a `ReturnInstruction`, but if
    // someone forgets to write a `return` statement in a function
    // with a non-void return type we generate an `UnreachedInstruction`.
    // In this case we still want to generate flow out of such functions
    // if they write to a parameter. So we pick the index of the
    // `UnreachedInstruction` as the index of this use.
    // Note that a function may have both a `ReturnInstruction` and an
    // `UnreachedInstruction`. If that's the case this predicate will
    // return multiple results. I don't think this is detrimental to
    // performance, however.
    exists(Instruction return |
      return instanceof ReturnInstruction or
      return instanceof UnreachedInstruction
    |
      block.getInstruction(index) = return and
      return.getEnclosingFunction() = p.getFunction()
    )
  }

  override Cpp::Location getLocation() {
    // Parameters can have multiple locations. When there's a unique location we use
    // that one, but if multiple locations exist we default to an unknown location.
    result = unique( | | p.getLocation())
    or
    not exists(unique( | | p.getLocation())) and
    result instanceof UnknownDefaultLocation
  }

  override BaseSourceVariableInstruction getBase() {
    exists(InitializeParameterInstruction init |
      init.getParameter() = p and
      // This is always a `VariableAddressInstruction`
      result = init.getAnOperand().getDef()
    )
  }
}

/**
 * A use that models a synthetic "last use" of a global variable just before a
 * function returns.
 *
 * We model global variable flow by:
 * - Inserting a last use of any global variable that's modified by a function
 * - Flowing from the last use to the `VariableNode` that represents the global
 *   variable.
 * - Flowing from the `VariableNode` to an "initial def" of the global variable
 * in any function that may read the global variable.
 * - Flowing from the initial definition to any subsequent uses of the global
 *   variable in the function body.
 *
 * For example, consider the following pair of functions:
 * ```cpp
 * int global;
 * int source();
 * void sink(int);
 *
 * void set_global() {
 *   global = source();
 * }
 *
 * void read_global() {
 *  sink(global);
 * }
 * ```
 * we insert global uses and defs so that (from the point-of-view of dataflow)
 * the above scenario looks like:
 * ```cpp
 * int global; // (1)
 * int source();
 * void sink(int);
 *
 * void set_global() {
 *   global = source();
 *   __global_use(global); // (2)
 * }
 *
 * void read_global() {
 *  global = __global_def; // (3)
 *  sink(global); // (4)
 * }
 * ```
 * and flow from `source()` to the argument of `sink` is then modeled as
 * follows:
 * 1. Flow from `source()` to `(2)` (via SSA).
 * 2. Flow from `(2)` to `(1)` (via a `jumpStep`).
 * 3. Flow from `(1)` to `(3)` (via a `jumpStep`).
 * 4. Flow from `(3)` to `(4)` (via SSA).
 */
class GlobalUse extends UseImpl, TGlobalUse {
  GlobalLikeVariable global;
  IRFunction f;

  GlobalUse() { this = TGlobalUse(global, f, ind) }

  override FinalGlobalValue getNode() { result.getGlobalUse() = this }

  override int getIndirection() { isGlobalUse(global, f, result, ind) }

  /** Gets the global variable associated with this use. */
  GlobalLikeVariable getVariable() { result = global }

  /** Gets the `IRFunction` whose body is exited from after this use. */
  IRFunction getIRFunction() { result = f }

  final override predicate hasIndexInBlock(IRBlock block, int index) {
    // Similar to the `FinalParameterUse` case, we want to generate flow out of
    // globals at any exit so that we can flow out of non-returning functions.
    // Obviously this isn't correct as we can't actually flow but the global flow
    // requires this if we want to flow into children.
    exists(Instruction return |
      return instanceof ReturnInstruction or
      return instanceof UnreachedInstruction
    |
      block.getInstruction(index) = return and
      return.getEnclosingIRFunction() = f
    )
  }

  override SourceVariable getSourceVariable() {
    sourceVariableIsGlobal(result, global, f, this.getIndirection())
  }

  final override Cpp::Location getLocation() { result = f.getLocation() }

  /**
   * Gets the type of this use after specifiers have been deeply stripped
   * and typedefs have been resolved.
   */
  Type getUnspecifiedType() { result = global.getUnspecifiedType() }

  /**
   * Gets the type of this use, after typedefs have been resolved.
   */
  Type getUnderlyingType() { result = global.getUnderlyingType() }

  override predicate isCertain() { any() }

  override BaseSourceVariableInstruction getBase() { none() }
}

/**
 * A definition that models a synthetic "initial definition" of a global
 * variable just after the function entry point.
 *
 * See the QLDoc for `GlobalUse` for how this is used.
 */
class GlobalDefImpl extends DefOrUseImpl, TGlobalDefImpl {
  GlobalLikeVariable global;
  IRFunction f;
  int indirectionIndex;

  GlobalDefImpl() { this = TGlobalDefImpl(global, f, indirectionIndex) }

  /** Gets the global variable associated with this definition. */
  GlobalLikeVariable getVariable() { result = global }

  /** Gets the `IRFunction` whose body is evaluated after this definition. */
  IRFunction getIRFunction() { result = f }

  /** Gets the global variable associated with this definition. */
  override int getIndirectionIndex() { result = indirectionIndex }

  /** Holds if this definition or use has index `index` in block `block`. */
  final override predicate hasIndexInBlock(IRBlock block, int index) {
    exists(EnterFunctionInstruction enter |
      enter = f.getEnterFunctionInstruction() and
      block.getInstruction(index) = enter
    )
  }

  /** Gets the global variable associated with this definition. */
  override SourceVariable getSourceVariable() {
    sourceVariableIsGlobal(result, global, f, this.getIndirection())
  }

  int getIndirection() { result = indirectionIndex }

  /**
   * Gets the type of this definition after specifiers have been deeply
   * stripped and typedefs have been resolved.
   */
  Type getUnspecifiedType() { result = global.getUnspecifiedType() }

  /**
   * Gets the type of this definition, after typedefs have been resolved.
   */
  Type getUnderlyingType() { result = global.getUnderlyingType() }

  override string toString() { result = "Def of " + this.getSourceVariable() }

  override Location getLocation() { result = f.getLocation() }

  override BaseSourceVariableInstruction getBase() { none() }
}

/**
 * Holds if `defOrUse1` is a definition which is first read by `use`,
 * or if `defOrUse1` is a use and `use` is a next subsequent use.
 *
 * In both cases, `use` can either be an explicit use written in the
 * source file, or it can be a phi node as computed by the SSA library.
 */
predicate adjacentDefRead(DefOrUse defOrUse1, UseOrPhi use) {
  exists(IRBlock bb1, int i1, SourceVariable v |
    defOrUse1
        .asDefOrUse()
        .hasIndexInBlock(pragma[only_bind_out](bb1), pragma[only_bind_out](i1),
          pragma[only_bind_out](v))
  |
    exists(IRBlock bb2, int i2, DefinitionExt def |
      adjacentDefReadExt(pragma[only_bind_into](def), pragma[only_bind_into](bb1),
        pragma[only_bind_into](i1), pragma[only_bind_into](bb2), pragma[only_bind_into](i2)) and
      def.getSourceVariable() = v and
      use.asDefOrUse().(UseImpl).hasIndexInBlock(bb2, i2, v)
    )
    or
    exists(PhiNode phi |
      lastRefRedefExt(_, bb1, i1, phi) and
      use.asPhi() = phi and
      phi.getSourceVariable() = pragma[only_bind_into](v)
    )
  )
}

/**
 * Holds if `globalDef` represents the initial definition of a global variable that
 * flows to `useOrPhi`.
 */
private predicate globalDefToUse(GlobalDef globalDef, UseOrPhi useOrPhi) {
  exists(IRBlock bb1, int i1, SourceVariable v |
    globalDef
        .hasIndexInBlock(pragma[only_bind_out](bb1), pragma[only_bind_out](i1),
          pragma[only_bind_out](v))
  |
    exists(IRBlock bb2, int i2 |
      adjacentDefReadExt(_, pragma[only_bind_into](bb1), pragma[only_bind_into](i1),
        pragma[only_bind_into](bb2), pragma[only_bind_into](i2)) and
      useOrPhi.asDefOrUse().hasIndexInBlock(bb2, i2, v)
    )
    or
    exists(PhiNode phi |
      lastRefRedefExt(_, bb1, i1, phi) and
      useOrPhi.asPhi() = phi and
      phi.getSourceVariable() = pragma[only_bind_into](v)
    )
  )
}

private predicate useToNode(UseOrPhi use, Node nodeTo) { use.getNode() = nodeTo }

pragma[noinline]
predicate outNodeHasAddressAndIndex(
  IndirectArgumentOutNode out, Operand address, int indirectionIndex
) {
  out.getAddressOperand() = address and
  out.getIndirectionIndex() = indirectionIndex
}

private predicate defToNode(Node nodeFrom, Def def, boolean uncertain) {
  (
    nodeHasOperand(nodeFrom, def.getValue().asOperand(), def.getIndirectionIndex())
    or
    nodeHasInstruction(nodeFrom, def.getValue().asInstruction(), def.getIndirectionIndex())
  ) and
  if def.isCertain() then uncertain = false else uncertain = true
}

/**
 * INTERNAL: Do not use.
 *
 * Holds if `nodeFrom` is the node that correspond to the definition or use `defOrUse`.
 */
predicate nodeToDefOrUse(Node nodeFrom, SsaDefOrUse defOrUse, boolean uncertain) {
  // Node -> Def
  defToNode(nodeFrom, defOrUse, uncertain)
  or
  // Node -> Use
  useToNode(defOrUse, nodeFrom) and
  uncertain = false
}

/**
 * Perform a single conversion-like step from `nFrom` to `nTo`. This relation
 * only holds when there is no use-use relation out of `nTo`.
 */
private predicate indirectConversionFlowStep(Node nFrom, Node nTo) {
  not exists(UseOrPhi defOrUse |
    nodeToDefOrUse(nTo, defOrUse, _) and
    adjacentDefRead(defOrUse, _)
  ) and
  (
    exists(Operand op1, Operand op2, int indirectionIndex, Instruction instr |
      hasOperandAndIndex(nFrom, op1, pragma[only_bind_into](indirectionIndex)) and
      hasOperandAndIndex(nTo, op2, pragma[only_bind_into](indirectionIndex)) and
      instr = op2.getDef() and
      conversionFlow(op1, instr, _, _)
    )
    or
    exists(Operand op1, Operand op2, int indirectionIndex, Instruction instr |
      hasOperandAndIndex(nFrom, op1, pragma[only_bind_into](indirectionIndex)) and
      hasOperandAndIndex(nTo, op2, indirectionIndex - 1) and
      instr = op2.getDef() and
      isDereference(instr, op1, _)
    )
  )
}

/**
 * The reason for this predicate is a bit annoying:
 * We cannot mark a `PointerArithmeticInstruction` that computes an offset based on some SSA
 * variable `x` as a use of `x` since this creates taint-flow in the following example:
 * ```c
 * int x = array[source]
 * sink(*array)
 * ```
 * This is because `source` would flow from the operand of `PointerArithmeticInstruction` to the
 * result of the instruction, and into the `IndirectOperand` that represents the value of `*array`.
 * Then, via use-use flow, flow will arrive at `*array` in `sink(*array)`.
 *
 * So this predicate recurses back along conversions and `PointerArithmeticInstruction`s to find the
 * first use that has provides use-use flow, and uses that target as the target of the `nodeFrom`.
 */
private predicate adjustForPointerArith(PostUpdateNode pun, UseOrPhi use) {
  exists(DefOrUse defOrUse, Node adjusted |
    indirectConversionFlowStep*(adjusted, pun.getPreUpdateNode()) and
    nodeToDefOrUse(adjusted, defOrUse, _) and
    adjacentDefRead(defOrUse, use)
  )
}

/**
 * Holds if `nodeFrom` flows to `nodeTo` because there is `def-use` or
 * `use-use` flow from `defOrUse` to `use`.
 *
 * `uncertain` is `true` if the `defOrUse` is an uncertain definition.
 */
private predicate localSsaFlow(
  SsaDefOrUse defOrUse, Node nodeFrom, UseOrPhi use, Node nodeTo, boolean uncertain
) {
  nodeToDefOrUse(nodeFrom, defOrUse, uncertain) and
  adjacentDefRead(defOrUse, use) and
  useToNode(use, nodeTo) and
  nodeFrom != nodeTo
}

private predicate ssaFlowImpl(SsaDefOrUse defOrUse, Node nodeFrom, Node nodeTo, boolean uncertain) {
  exists(UseOrPhi use |
    localSsaFlow(defOrUse, nodeFrom, use, nodeTo, uncertain)
    or
    // Initial global variable value to a first use
    nodeFrom.(InitialGlobalValue).getGlobalDef() = defOrUse and
    globalDefToUse(defOrUse, use) and
    useToNode(use, nodeTo) and
    uncertain = false
  )
}

/**
 * Holds if `def` is the corresponding definition of
 * the SSA library's `definition`.
 */
private DefinitionExt ssaDefinition(Def def) {
  exists(IRBlock block, int i, SourceVariable sv |
    def.hasIndexInBlock(block, i, sv) and
    result.definesAt(sv, block, i, _)
  )
}

/** Gets a node that represents the prior definition of `node`. */
private Node getAPriorDefinition(SsaDefOrUse defOrUse) {
  exists(IRBlock bb, int i, SourceVariable sv, DefinitionExt def, DefOrUse defOrUse0 |
    lastRefRedefExt(pragma[only_bind_into](def), pragma[only_bind_into](bb),
      pragma[only_bind_into](i), ssaDefinition(defOrUse)) and
    def.getSourceVariable() = sv and
    defOrUse0.hasIndexInBlock(bb, i, sv) and
    nodeToDefOrUse(result, defOrUse0, _)
  )
}

private predicate inOut(FIO::FunctionInput input, FIO::FunctionOutput output) {
  exists(int indirectionIndex |
    input.isQualifierObject(indirectionIndex) and
    output.isQualifierObject(indirectionIndex)
    or
    exists(int i |
      input.isParameterDeref(i, indirectionIndex) and
      output.isParameterDeref(i, indirectionIndex)
    )
  )
}

/**
 * Holds if there should not be use-use flow out of `n`. That is, `n` is
 * an out-barrier to use-use flow. This includes:
 *
 * - an input to a call that would be assumed to have use-use flow to the same
 *   argument as an output, but this flow should be blocked because the
 *   function is modeled with another flow to that output (for example the
 *   first argument of `strcpy`).
 * - a conversion that flows to such an input.
 */
private predicate modeledFlowBarrier(Node n) {
  exists(
    FIO::FunctionInput input, FIO::FunctionOutput output, CallInstruction call,
    PartialFlow::PartialFlowFunction partialFlowFunc
  |
    n = callInput(call, input) and
    inOut(input, output) and
    exists(callOutput(call, output)) and
    partialFlowFunc = call.getStaticCallTarget() and
    not partialFlowFunc.isPartialWrite(output)
  |
    call.getStaticCallTarget().(DataFlow::DataFlowFunction).hasDataFlow(_, output)
    or
    call.getStaticCallTarget().(Taint::TaintFunction).hasTaintFlow(_, output)
  )
  or
  exists(Operand operand, Instruction instr, Node n0, int indirectionIndex |
    modeledFlowBarrier(n0) and
    nodeHasInstruction(n0, instr, indirectionIndex) and
    conversionFlow(operand, instr, false, _) and
    nodeHasOperand(n, operand, indirectionIndex)
  )
}

/** Holds if there is def-use or use-use flow from `nodeFrom` to `nodeTo`. */
predicate ssaFlow(Node nodeFrom, Node nodeTo) {
  exists(Node nFrom, boolean uncertain, SsaDefOrUse defOrUse |
    ssaFlowImpl(defOrUse, nFrom, nodeTo, uncertain) and
    not modeledFlowBarrier(nFrom) and
    nodeFrom != nodeTo
  |
    if uncertain = true then nodeFrom = [nFrom, getAPriorDefinition(defOrUse)] else nodeFrom = nFrom
  )
}

private predicate isArgumentOfCallableInstruction(DataFlowCall call, Instruction instr) {
  isArgumentOfCallableOperand(call, unique( | | getAUse(instr)))
}

private predicate isArgumentOfCallableOperand(DataFlowCall call, Operand operand) {
  operand.(ArgumentOperand).getCall() = call
  or
  exists(FieldAddressInstruction fai |
    fai.getObjectAddressOperand() = operand and
    isArgumentOfCallableInstruction(call, fai)
  )
  or
  exists(Instruction deref |
    isArgumentOfCallableInstruction(call, deref) and
    isDereference(deref, operand, _)
  )
  or
  exists(Instruction instr |
    isArgumentOfCallableInstruction(call, instr) and
    conversionFlow(operand, instr, _, _)
  )
}

private predicate isArgumentOfCallable(DataFlowCall call, Node n) {
  isArgumentOfCallableOperand(call, n.asOperand())
  or
  exists(Operand op |
    n.(IndirectOperand).hasOperandAndIndirectionIndex(op, _) and
    isArgumentOfCallableOperand(call, op)
  )
  or
  exists(Instruction instr |
    n.(IndirectInstruction).hasInstructionAndIndirectionIndex(instr, _) and
    isArgumentOfCallableInstruction(call, instr)
  )
}

/**
 * Holds if there is use-use flow from `pun`'s pre-update node to `n`.
 */
private predicate postUpdateNodeToFirstUse(PostUpdateNode pun, Node n) {
  exists(UseOrPhi use |
    adjustForPointerArith(pun, use) and
    useToNode(use, n)
  )
}

private predicate stepUntilNotInCall(DataFlowCall call, Node n1, Node n2) {
  isArgumentOfCallable(call, n1) and
  exists(Node mid | localSsaFlow(_, n1, _, mid, _) |
    isArgumentOfCallable(call, mid) and
    stepUntilNotInCall(call, mid, n2)
    or
    not isArgumentOfCallable(call, mid) and
    mid = n2
  )
}

bindingset[n1, n2]
pragma[inline_late]
private predicate isArgumentOfSameCall(DataFlowCall call, Node n1, Node n2) {
  isArgumentOfCallable(call, n1) and isArgumentOfCallable(call, n2)
}

/**
 * Holds if there is def-use or use-use flow from `pun` to `nodeTo`.
 *
 * Note: This is more complex than it sounds. Consider a call such as:
 * ```cpp
 * write_first_argument(x, x);
 * sink(x);
 * ```
 * Assume flow comes out of the first argument to `write_first_argument`. We
 * don't want flow to go to the `x` that's also an argument to
 * `write_first_argument` (because we just flowed out of that function, and we
 * don't want to flow back into it again).
 *
 * We do, however, want flow from the output argument to `x` on the next line, and
 * similarly we want flow from the second argument of `write_first_argument` to `x`
 * on the next line.
 */
predicate postUpdateFlow(PostUpdateNode pun, Node nodeTo) {
  exists(Node preUpdate, Node mid |
    preUpdate = pun.getPreUpdateNode() and
    postUpdateNodeToFirstUse(pun, mid)
  |
    exists(DataFlowCall call |
      isArgumentOfSameCall(call, preUpdate, mid) and
      stepUntilNotInCall(call, mid, nodeTo)
    )
    or
    not isArgumentOfSameCall(_, preUpdate, mid) and
    nodeTo = mid
  )
}

/**
 * Holds if `use` is a use of `sv` and is a next adjacent use of `phi` in
 * index `i1` in basic block `bb1`.
 *
 * This predicate exists to prevent an early join of `adjacentDefRead` with `definesAt`.
 */
pragma[nomagic]
private predicate fromPhiNodeToUse(PhiNode phi, SourceVariable sv, IRBlock bb1, int i1, UseOrPhi use) {
  exists(IRBlock bb2, int i2 |
    use.asDefOrUse().hasIndexInBlock(bb2, i2, sv) and
    adjacentDefReadExt(pragma[only_bind_into](phi), pragma[only_bind_into](bb1),
      pragma[only_bind_into](i1), pragma[only_bind_into](bb2), pragma[only_bind_into](i2))
  )
}

/** Holds if `nodeTo` receives flow from the phi node `nodeFrom`. */
predicate fromPhiNode(SsaPhiNode nodeFrom, Node nodeTo) {
  exists(PhiNode phi, SourceVariable sv, IRBlock bb1, int i1, UseOrPhi use |
    phi = nodeFrom.getPhiNode() and
    phi.definesAt(sv, bb1, i1, _) and
    useToNode(use, nodeTo)
  |
    fromPhiNodeToUse(phi, sv, bb1, i1, use)
    or
    exists(PhiNode phiTo |
      phi != phiTo and
      lastRefRedefExt(phi, bb1, i1, phiTo) and
      nodeTo.(SsaPhiNode).getPhiNode() = phiTo
    )
  )
}

private predicate sourceVariableIsGlobal(
  SourceVariable sv, GlobalLikeVariable global, IRFunction func, int indirectionIndex
) {
  exists(IRVariable irVar, BaseIRVariable base |
    sourceVariableHasBaseAndIndex(sv, base, indirectionIndex) and
    irVar = base.getIRVariable() and
    irVar.getEnclosingIRFunction() = func and
    global = irVar.getAst() and
    not irVar instanceof IRDynamicInitializationFlag
  )
}

private module SsaInput implements SsaImplCommon::InputSig<Location> {
  import InputSigCommon
  import SourceVariables

  /**
   * Holds if the `i`'th write in block `bb` writes to the variable `v`.
   * `certain` is `true` if the write is guaranteed to overwrite the entire variable.
   */
  predicate variableWrite(IRBlock bb, int i, SourceVariable v, boolean certain) {
    DataFlowImplCommon::forceCachingInSameStage() and
    (
      exists(DefImpl def | def.hasIndexInBlock(bb, i, v) |
        if def.isCertain() then certain = true else certain = false
      )
      or
      exists(GlobalDefImpl global |
        global.hasIndexInBlock(bb, i, v) and
        certain = true
      )
    )
  }

  /**
   * Holds if the `i`'th read in block `bb` reads to the variable `v`.
   * `certain` is `true` if the read is guaranteed. For C++, this is always the case.
   */
  predicate variableRead(IRBlock bb, int i, SourceVariable v, boolean certain) {
    exists(UseImpl use | use.hasIndexInBlock(bb, i, v) |
      if use.isCertain() then certain = true else certain = false
    )
    or
    exists(GlobalUse global |
      global.hasIndexInBlock(bb, i, v) and
      certain = true
    )
  }
}

/**
 * The final SSA predicates used for dataflow purposes.
 */
cached
module SsaCached {
  /**
   * Holds if `def` is accessed at index `i1` in basic block `bb1` (either a read
   * or a write), `def` is read at index `i2` in basic block `bb2`, and there is a
   * path between them without any read of `def`.
   */
  cached
  predicate adjacentDefReadExt(DefinitionExt def, IRBlock bb1, int i1, IRBlock bb2, int i2) {
    SsaImpl::adjacentDefReadExt(def, _, bb1, i1, bb2, i2)
  }

  /**
   * Holds if the node at index `i` in `bb` is a last reference to SSA definition
   * `def`. The reference is last because it can reach another write `next`,
   * without passing through another read or write.
   */
  cached
  predicate lastRefRedefExt(DefinitionExt def, IRBlock bb, int i, DefinitionExt next) {
    SsaImpl::lastRefRedefExt(def, _, bb, i, next)
  }
}

cached
private newtype TSsaDefOrUse =
  TDefOrUse(DefOrUseImpl defOrUse) {
    defOrUse instanceof UseImpl
    or
    // Like in the pruning stage, we only include definition that's live after the
    // write as the final definitions computed by SSA.
    exists(DefinitionExt def, SourceVariable sv, IRBlock bb, int i |
      def.definesAt(sv, bb, i, _) and
      defOrUse.(DefImpl).hasIndexInBlock(bb, i, sv)
    )
  } or
  TPhi(PhiNode phi) or
  TGlobalDef(GlobalDefImpl global)

abstract private class SsaDefOrUse extends TSsaDefOrUse {
  /** Gets a textual representation of this element. */
  string toString() { none() }

  /** Gets the underlying non-phi definition or use. */
  DefOrUseImpl asDefOrUse() { none() }

  /** Gets the underlying phi node. */
  PhiNode asPhi() { none() }

  /** Gets the location of this element. */
  abstract Location getLocation();
}

class DefOrUse extends TDefOrUse, SsaDefOrUse {
  DefOrUseImpl defOrUse;

  DefOrUse() { this = TDefOrUse(defOrUse) }

  final override DefOrUseImpl asDefOrUse() { result = defOrUse }

  final override Location getLocation() { result = defOrUse.getLocation() }

  final SourceVariable getSourceVariable() { result = defOrUse.getSourceVariable() }

  override string toString() { result = defOrUse.toString() }

  /**
   * Holds if this definition (or use) has index `index` in block `block`,
   * and is a definition (or use) of the variable `sv`.
   */
  predicate hasIndexInBlock(IRBlock block, int index, SourceVariable sv) {
    defOrUse.hasIndexInBlock(block, index, sv)
  }
}

class GlobalDef extends TGlobalDef, SsaDefOrUse {
  GlobalDefImpl global;

  GlobalDef() { this = TGlobalDef(global) }

  /** Gets the location of this definition. */
  final override Location getLocation() { result = global.getLocation() }

  /** Gets a textual representation of this definition. */
  override string toString() { result = global.toString() }

  /**
   * Holds if this definition has index `index` in block `block`, and
   * is a definition of the variable `sv`.
   */
  predicate hasIndexInBlock(IRBlock block, int index, SourceVariable sv) {
    global.hasIndexInBlock(block, index, sv)
  }

  /** Gets the indirection index of this definition. */
  int getIndirection() { result = global.getIndirection() }

  /** Gets the indirection index of this definition. */
  int getIndirectionIndex() { result = global.getIndirectionIndex() }

  /**
   * Gets the type of this definition after specifiers have been deeply stripped
   * and typedefs have been resolved.
   */
  DataFlowType getUnspecifiedType() { result = global.getUnspecifiedType() }

  /**
   * Gets the type of this definition, after typedefs have been resolved.
   */
  DataFlowType getUnderlyingType() { result = global.getUnderlyingType() }

  /** Gets the `IRFunction` whose body is evaluated after this definition. */
  IRFunction getIRFunction() { result = global.getIRFunction() }

  /** Gets the global variable associated with this definition. */
  GlobalLikeVariable getVariable() { result = global.getVariable() }
}

class Phi extends TPhi, SsaDefOrUse {
  PhiNode phi;

  Phi() { this = TPhi(phi) }

  final override PhiNode asPhi() { result = phi }

  final override Location getLocation() { result = phi.getBasicBlock().getLocation() }

  override string toString() { result = "Phi" }

  SsaPhiNode getNode() { result.getPhiNode() = phi }
}

class UseOrPhi extends SsaDefOrUse {
  UseOrPhi() {
    this.asDefOrUse() instanceof UseImpl
    or
    this instanceof Phi
  }

  final override Location getLocation() {
    result = this.asDefOrUse().getLocation() or result = this.(Phi).getLocation()
  }

  final Node getNode() {
    result = this.(Phi).getNode()
    or
    result = this.asDefOrUse().(UseImpl).getNode()
  }
}

class Def extends DefOrUse {
  override DefImpl defOrUse;

  Operand getAddressOperand() { result = defOrUse.getAddressOperand() }

  Instruction getAddress() { result = this.getAddressOperand().getDef() }

  /**
   * Gets the indirection index of this definition.
   *
   * This predicate ensures that joins go from `defOrUse` to the result
   * instead of the other way around.
   */
  pragma[inline]
  int getIndirectionIndex() {
    pragma[only_bind_into](result) = pragma[only_bind_out](defOrUse).getIndirectionIndex()
  }

  /**
   * Gets the indirection level that this definition is writing to.
   * For instance, `x = y` is a definition of `x` at indirection level 1 and
   * `*x = y` is a definition of `x` at indirection level 2.
   *
   * This predicate ensures that joins go from `defOrUse` to the result
   * instead of the other way around.
   */
  pragma[inline]
  int getIndirection() {
    pragma[only_bind_into](result) = pragma[only_bind_out](defOrUse).getIndirection()
  }

  Node0Impl getValue() { result = defOrUse.getValue() }

  predicate isCertain() { defOrUse.isCertain() }
}

private module SsaImpl = SsaImplCommon::Make<Location, SsaInput>;

class PhiNode extends SsaImpl::DefinitionExt {
  PhiNode() {
    this instanceof SsaImpl::PhiNode or
    this instanceof SsaImpl::PhiReadNode
  }

  /**
   * Holds if this phi node is a phi-read node.
   *
   * Phi-read nodes are like normal phi nodes, but they are inserted based
   * on reads instead of writes.
   */
  predicate isPhiRead() { this instanceof SsaImpl::PhiReadNode }
}

class DefinitionExt = SsaImpl::DefinitionExt;

class UncertainWriteDefinition = SsaImpl::UncertainWriteDefinition;

import SsaCached
