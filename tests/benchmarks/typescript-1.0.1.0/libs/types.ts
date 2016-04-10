// <reference path="core.ts"/>

// <reference path="scanner.ts"/>

/////////////////////////////////////////////////////////////////////////
//
//  RefScript

type INode        = ts.Node<Immutable>
type INodeLinks   = ts.NodeLinks<Immutable>
type ISymbol      = ts.Symbol<Immutable>
type ISymbolLinks = ts.SymbolLinks<Immutable>
type IType        = ts.Type<Immutable>
type ISignature   = ts.Signature<Immutable>
type IDeclaration = ts.Declaration<Immutable>
type ISourceFile  = ts.SourceFile<Immutable>

/*@ predicate non_zero                           (b) = (b /= lit "#x00000000" (BitVec Size32)) */

/*@ predicate typeflags_any                      (v) = (v = lit "#x00000001" (BitVec Size32)) */
/*@ predicate typeflags_string                   (v) = (v = lit "#x00000002" (BitVec Size32)) */
/*@ predicate typeflags_number                   (v) = (v = lit "#x00000004" (BitVec Size32)) */
/*@ predicate typeflags_boolean                  (v) = (v = lit "#x00000008" (BitVec Size32)) */
/*@ predicate typeflags_void                     (v) = (v = lit "#x00000010" (BitVec Size32)) */
/*@ predicate typeflags_undefined                (v) = (v = lit "#x00000020" (BitVec Size32)) */
/*@ predicate typeflags_null                     (v) = (v = lit "#x00000040" (BitVec Size32)) */
/*@ predicate typeflags_enum                     (v) = (v = lit "#x00000080" (BitVec Size32)) */
/*@ predicate typeflags_stringliteral            (v) = (v = lit "#x00000100" (BitVec Size32)) */
/*@ predicate typeflags_typeparameter            (v) = (v = lit "#x00000200" (BitVec Size32)) */
/*@ predicate typeflags_class                    (v) = (v = lit "#x00000400" (BitVec Size32)) */
/*@ predicate typeflags_interface                (v) = (v = lit "#x00000800" (BitVec Size32)) */
/*@ predicate typeflags_reference                (v) = (v = lit "#x00001000" (BitVec Size32)) */
/*@ predicate typeflags_anonymous                (v) = (v = lit "#x00002000" (BitVec Size32)) */
/*@ predicate typeflags_fromsignature            (v) = (v = lit "#x00004000" (BitVec Size32)) */
/*@ predicate typeflags_objecttype               (v) = (v = lit "#x00003C00" (BitVec Size32)) */

/*@ predicate symbolflags_variable               (v) = (v = lit "#x00000001" (BitVec Size32)) */
/*@ predicate symbolflags_property               (v) = (v = lit "#x00000002" (BitVec Size32)) */
/*@ predicate symbolflags_enummember             (v) = (v = lit "#x00000004" (BitVec Size32)) */
/*@ predicate symbolflags_function               (v) = (v = lit "#x00000008" (BitVec Size32)) */
/*@ predicate symbolflags_class                  (v) = (v = lit "#x00000010" (BitVec Size32)) */
/*@ predicate symbolflags_interface              (v) = (v = lit "#x00000020" (BitVec Size32)) */
/*@ predicate symbolflags_enum                   (v) = (v = lit "#x00000040" (BitVec Size32)) */
/*@ predicate symbolflags_valuemodule            (v) = (v = lit "#x00000080" (BitVec Size32)) */
/*@ predicate symbolflags_namespacemodule        (v) = (v = lit "#x00000100" (BitVec Size32)) */
/*@ predicate symbolflags_typeliteral            (v) = (v = lit "#x00000200" (BitVec Size32)) */
/*@ predicate symbolflags_objectliteral          (v) = (v = lit "#x00000400" (BitVec Size32)) */
/*@ predicate symbolflags_method                 (v) = (v = lit "#x00000800" (BitVec Size32)) */
/*@ predicate symbolflags_constructor            (v) = (v = lit "#x00001000" (BitVec Size32)) */
/*@ predicate symbolflags_getaccessor            (v) = (v = lit "#x00002000" (BitVec Size32)) */
/*@ predicate symbolflags_setaccessor            (v) = (v = lit "#x00004000" (BitVec Size32)) */
/*@ predicate symbolflags_callsignature          (v) = (v = lit "#x00008000" (BitVec Size32)) */
/*@ predicate symbolflags_constructsignature     (v) = (v = lit "#x00010000" (BitVec Size32)) */
/*@ predicate symbolflags_indexsignature         (v) = (v = lit "#x00020000" (BitVec Size32)) */
/*@ predicate symbolflags_typeparameter          (v) = (v = lit "#x00040000" (BitVec Size32)) */
/*@ predicate symbolflags_exportvalue            (v) = (v = lit "#x00080000" (BitVec Size32)) */
/*@ predicate symbolflags_exporttype             (v) = (v = lit "#x00100000" (BitVec Size32)) */
/*@ predicate symbolflags_exportnamespace        (v) = (v = lit "#x00200000" (BitVec Size32)) */
/*@ predicate symbolflags_import                 (v) = (v = lit "#x00400000" (BitVec Size32)) */
/*@ predicate symbolflags_instantiated           (v) = (v = lit "#x00800000" (BitVec Size32)) */
/*@ predicate symbolflags_merged                 (v) = (v = lit "#x01000000" (BitVec Size32)) */
/*@ predicate symbolflags_transient              (v) = (v = lit "#x02000000" (BitVec Size32)) */
/*@ predicate symbolflags_prototype              (v) = (v = lit "#x04000000" (BitVec Size32)) */

/*@ predicate mask_typeflags_any                 (v) = (non_zero(bvand v (lit "#x00000001" (BitVec Size32)))) */
/*@ predicate mask_typeflags_string              (v) = (non_zero(bvand v (lit "#x00000002" (BitVec Size32)))) */
/*@ predicate mask_typeflags_number              (v) = (non_zero(bvand v (lit "#x00000004" (BitVec Size32)))) */
/*@ predicate mask_typeflags_boolean             (v) = (non_zero(bvand v (lit "#x00000008" (BitVec Size32)))) */
/*@ predicate mask_typeflags_void                (v) = (non_zero(bvand v (lit "#x00000010" (BitVec Size32)))) */
/*@ predicate mask_typeflags_undefined           (v) = (non_zero(bvand v (lit "#x00000020" (BitVec Size32)))) */
/*@ predicate mask_typeflags_null                (v) = (non_zero(bvand v (lit "#x00000040" (BitVec Size32)))) */
/*@ predicate mask_typeflags_enum                (v) = (non_zero(bvand v (lit "#x00000080" (BitVec Size32)))) */
/*@ predicate mask_typeflags_stringliteral       (v) = (non_zero(bvand v (lit "#x00000100" (BitVec Size32)))) */
/*@ predicate mask_typeflags_typeparameter       (v) = (non_zero(bvand v (lit "#x00000200" (BitVec Size32)))) */
/*@ predicate mask_typeflags_class               (v) = (non_zero(bvand v (lit "#x00000400" (BitVec Size32)))) */
/*@ predicate mask_typeflags_interface           (v) = (non_zero(bvand v (lit "#x00000800" (BitVec Size32)))) */
/*@ predicate mask_typeflags_reference           (v) = (non_zero(bvand v (lit "#x00001000" (BitVec Size32)))) */
/*@ predicate mask_typeflags_anonymous           (v) = (non_zero(bvand v (lit "#x00002000" (BitVec Size32)))) */
/*@ predicate mask_typeflags_fromsignature       (v) = (non_zero(bvand v (lit "#x00004000" (BitVec Size32)))) */
/*@ predicate mask_typeflags_objecttype          (v) = (non_zero(bvand v (lit "#x00003C00" (BitVec Size32)))) */

/*@ predicate mask_symbolflags_variable          (v) = (non_zero(bvand v (lit "#x00000001" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_property          (v) = (non_zero(bvand v (lit "#x00000002" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_enummember        (v) = (non_zero(bvand v (lit "#x00000004" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_function          (v) = (non_zero(bvand v (lit "#x00000008" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_class             (v) = (non_zero(bvand v (lit "#x00000010" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_interface         (v) = (non_zero(bvand v (lit "#x00000020" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_enum              (v) = (non_zero(bvand v (lit "#x00000040" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_valuemodule       (v) = (non_zero(bvand v (lit "#x00000080" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_namespacemodule   (v) = (non_zero(bvand v (lit "#x00000100" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_typeliteral       (v) = (non_zero(bvand v (lit "#x00000200" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_objectliteral     (v) = (non_zero(bvand v (lit "#x00000400" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_method            (v) = (non_zero(bvand v (lit "#x00000800" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_constructor       (v) = (non_zero(bvand v (lit "#x00001000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_getaccessor       (v) = (non_zero(bvand v (lit "#x00002000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_setaccessor       (v) = (non_zero(bvand v (lit "#x00004000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_callsignature     (v) = (non_zero(bvand v (lit "#x00008000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_constructsignature(v) = (non_zero(bvand v (lit "#x00010000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_indexsignature    (v) = (non_zero(bvand v (lit "#x00020000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_typeparameter     (v) = (non_zero(bvand v (lit "#x00040000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_exportvalue       (v) = (non_zero(bvand v (lit "#x00080000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_exporttype        (v) = (non_zero(bvand v (lit "#x00100000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_exportnamespace   (v) = (non_zero(bvand v (lit "#x00200000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_import            (v) = (non_zero(bvand v (lit "#x00400000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_instantiated      (v) = (non_zero(bvand v (lit "#x00800000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_merged            (v) = (non_zero(bvand v (lit "#x01000000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_transient         (v) = (non_zero(bvand v (lit "#x02000000" (BitVec Size32)))) */
/*@ predicate mask_symbolflags_prototype         (v) = (non_zero(bvand v (lit "#x04000000" (BitVec Size32)))) */

/*@ predicate type_flags(v,o) = (mask_typeflags_objecttype(v) =>  extends_interface(o,"ts.ObjectType"))         &&
                                (mask_typeflags_anonymous (v) =>  extends_interface(o,"ts.ResolvedObjectType")) &&
                                (mask_typeflags_reference (v) =>  extends_interface(o,"ts.TypeReference"))
 */

//
/////////////////////////////////////////////////////////////////////////




module ts {

    export interface Map<M extends ReadOnly, T> {
        [index: string]: T;
    }


    export interface TextRange<M extends ReadOnly> {
        pos: number;
        end: number;
    }

    // token > SyntaxKind.Identifer => token is a keyword
    export enum SyntaxKind {
        Unknown,
        EndOfFileToken,
        // Literals
        NumericLiteral,
        StringLiteral,
        RegularExpressionLiteral,
        // Punctuation
        OpenBraceToken,
        CloseBraceToken,
        OpenParenToken,
        CloseParenToken,
        OpenBracketToken,
        CloseBracketToken,
        DotToken,
        // DotDotDotToken,
        // SemicolonToken,
        // CommaToken,
        // LessThanToken,
        // GreaterThanToken,
        // LessThanEqualsToken,
        // GreaterThanEqualsToken,
        // EqualsEqualsToken,
        // ExclamationEqualsToken,
        // EqualsEqualsEqualsToken,
        // ExclamationEqualsEqualsToken,
        // EqualsGreaterThanToken,
        // PlusToken,
        // MinusToken,
        // AsteriskToken,
        // SlashToken,
        // PercentToken,
        // PlusPlusToken,
        // MinusMinusToken,
        // LessThanLessThanToken,
        // GreaterThanGreaterThanToken,
        // GreaterThanGreaterThanGreaterThanToken,
        // AmpersandToken,
        // BarToken,
        // CaretToken,
        // ExclamationToken,
        // TildeToken,
        // AmpersandAmpersandToken,
        // BarBarToken,
        // QuestionToken,
        // ColonToken,
        // // Assignments
        // EqualsToken,
        // PlusEqualsToken,
        // MinusEqualsToken,
        // AsteriskEqualsToken,
        // SlashEqualsToken,
        // PercentEqualsToken,
        // LessThanLessThanEqualsToken,
        // GreaterThanGreaterThanEqualsToken,
        // GreaterThanGreaterThanGreaterThanEqualsToken,
        // AmpersandEqualsToken,
        // BarEqualsToken,
        // CaretEqualsToken,
        // // Identifiers
        // Identifier,
        // // Reserved words
        // BreakKeyword,
        // CaseKeyword,
        // CatchKeyword,
        // ClassKeyword,
        // ConstKeyword,
        // ContinueKeyword,
        // DebuggerKeyword,
        // DefaultKeyword,
        // DeleteKeyword,
        // DoKeyword,
        // ElseKeyword,
        // EnumKeyword,
        // ExportKeyword,
        // ExtendsKeyword,
        // FalseKeyword,
        // FinallyKeyword,
        // ForKeyword,
        // FunctionKeyword,
        // IfKeyword,
        // ImportKeyword,
        // InKeyword,
        // InstanceOfKeyword,
        // NewKeyword,
        // NullKeyword,
        // ReturnKeyword,
        // SuperKeyword,
        // SwitchKeyword,
        // ThisKeyword,
        // ThrowKeyword,
        // TrueKeyword,
        // TryKeyword,
        // TypeOfKeyword,
        // VarKeyword,
        // VoidKeyword,
        // WhileKeyword,
        // WithKeyword,
        // // Strict mode reserved words
        // ImplementsKeyword,
        // InterfaceKeyword,
        // LetKeyword,
        // PackageKeyword,
        // PrivateKeyword,
        // ProtectedKeyword,
        // PublicKeyword,
        // StaticKeyword,
        // YieldKeyword,
        // // TypeScript keywords
        // AnyKeyword,
        // BooleanKeyword,
        // ConstructorKeyword,
        // DeclareKeyword,
        // GetKeyword,
        // ModuleKeyword,
        // RequireKeyword,
        // NumberKeyword,
        // SetKeyword,
        // StringKeyword,
        // // Parse tree nodes
        // Missing,
        // // Names
        // QualifiedName,
        // Signature elements
        TypeParameter,
        Parameter,
        // // TypeMember
        // Property,
        // Method,
        // Constructor,
        // GetAccessor,
        // SetAccessor,
        // CallSignature,
        // ConstructSignature,
        // IndexSignature,
        // // Type
        // TypeReference,
        // TypeQuery,
        // TypeLiteral,
        // ArrayType,
        // // Expression
        // ArrayLiteral,
        // ObjectLiteral,
        // PropertyAssignment,
        // PropertyAccess,
        // IndexedAccess,
        // CallExpression,
        // NewExpression,
        // TypeAssertion,
        // ParenExpression,
        // FunctionExpression,
        // ArrowFunction,
        // PrefixOperator,
        // PostfixOperator,
        // BinaryExpression,
        // ConditionalExpression,
        // OmittedExpression,
        // // Element
        // Block,
        // VariableStatement,
        // EmptyStatement,
        // ExpressionStatement,
        // IfStatement,
        // DoStatement,
        // WhileStatement,
        // ForStatement,
        // ForInStatement,
        // ContinueStatement,
        // BreakStatement,
        // ReturnStatement,
        // WithStatement,
        // SwitchStatement,
        // CaseClause,
        // DefaultClause,
        // LabelledStatement,
        // ThrowStatement,
        // TryStatement,
        // TryBlock,
        // CatchBlock,
        // FinallyBlock,
        // DebuggerStatement,
        // VariableDeclaration,
        // FunctionDeclaration,
        // FunctionBlock,
        ClassDeclaration,
        InterfaceDeclaration,
        EnumDeclaration,
        ModuleDeclaration,
        // ModuleBlock,
        ImportDeclaration,
        // ExportAssignment,
        // // Enum
        // EnumMember,

        // Top-level nodes
        SourceFile,
        Program,

        // // Synthesized list
        // SyntaxList,
        // // Enum value count
        // Count,
        //
        // // Markers
        // FirstAssignment = EqualsToken,
        // LastAssignment = CaretEqualsToken,
        // FirstReservedWord = BreakKeyword,
        // LastReservedWord = WithKeyword,
        // FirstKeyword = BreakKeyword,
        // LastKeyword = StringKeyword,
        // FirstFutureReservedWord = ImplementsKeyword,
        // LastFutureReservedWord = YieldKeyword,
        // FirstTypeNode = TypeReference,
        // LastTypeNode = ArrayType,
        // FirstPunctuation = OpenBraceToken,
        // LastPunctuation = CaretEqualsToken
    }

    export enum NodeFlags {
        Export           = 0x00000001,  // Declarations
        Ambient          = 0x00000002,  // Declarations
        QuestionMark     = 0x00000004,  // Parameter/Property/Method
        Rest             = 0x00000008,  // Parameter
        Public           = 0x00000010,  // Property/Method
        Private          = 0x00000020,  // Property/Method
        Static           = 0x00000040,  // Property/Method
        MultiLine        = 0x00000080,  // Multi-line array or object literal
        Synthetic        = 0x00000100,  // Synthetic node (for full fidelity)
        DeclarationFile  = 0x00000200,  // Node<M> is a .d.ts file

        // TODO
        // Modifier = Export | Ambient | Public | Private | Static
    }

    export interface Node<M extends ReadOnly> extends TextRange<M> {
        /*@ (Immutable) kind: SyntaxKind */
        kind: SyntaxKind;

        /*@ (Immutable) flags: bitvector32 */
        flags: NodeFlags;

        /*@ (Mutable) id?: number */
        id?: number;                    // Unique id (used to look up NodeLinks)

        /*@ parent?: INode */
        parent?: Node<M>;               // Parent node (initialized by binding)

        symbol?: Symbol<M>;             // Symbol declared by node (initialized by binding)
        locals?: SymbolTable<M>;        // Locals associated with node (initialized by binding)
        nextContainer?: Node<M>;        // Next container in declaration order (initialized by binding)
        localSymbol?: Symbol<M>;        // Local symbol declared by node (initialized by binding only for exported nodes)
    }

    export interface NodeArray<M extends ReadOnly, T> extends Array<M, T>, TextRange<M> { }

    export interface Identifier<M extends ReadOnly> extends Node<M> {
        text: string;                 // Text of identifier (with escapes converted to characters)
    }

    export interface QualifiedName<M extends ReadOnly> extends Node<M> {
        // Must have same layout as PropertyAccess
        left: EntityName<M>;
        right: Identifier<M>;
    }

    export interface EntityName<M extends ReadOnly> extends Node<M> {
        // Identifier, QualifiedName, or Missing
    }

    export interface ParsedSignature<M extends ReadOnly> {
        typeParameters?: NodeArray<M, TypeParameterDeclaration<M>>;
        parameters: NodeArray<M, ParameterDeclaration<M>>;
        type?: TypeNode<M>;
    }

    export interface Declaration<M extends ReadOnly> extends Node<M> {
       name?: Identifier<M>;
    }

    export interface TypeParameterDeclaration<M extends ReadOnly> extends Declaration<M> {
        constraint?: TypeNode<M>;
    }

    export interface SignatureDeclaration<M extends ReadOnly> extends Declaration<M>, ParsedSignature<M> { }

    export interface VariableDeclaration<M extends ReadOnly> extends Declaration<M> {
        type?: TypeNode<M>;
        initializer?: Expression<M>;
    }

    export interface PropertyDeclaration<M extends ReadOnly> extends VariableDeclaration<M> { }

    export interface ParameterDeclaration<M extends ReadOnly> extends VariableDeclaration<M> { }

    export interface FunctionDeclaration<M extends ReadOnly> extends Declaration<M>, ParsedSignature<M> {
        body?: Node<M>;  // Block or Expression
    }

    export interface MethodDeclaration<M extends ReadOnly> extends FunctionDeclaration<M> { }

    export interface ConstructorDeclaration<M extends ReadOnly> extends FunctionDeclaration<M> { }

    export interface AccessorDeclaration<M extends ReadOnly> extends FunctionDeclaration<M> { }

    export interface TypeNode<M extends ReadOnly> extends Node<M> { }

    export interface TypeReferenceNode<M extends ReadOnly> extends TypeNode<M> {
        typeName: EntityName<M>;
        typeArguments?: NodeArray<M, TypeNode<M>>;
    }

    export interface TypeQueryNode<M extends ReadOnly> extends TypeNode<M> {
        exprName: EntityName<M>;
    }

    export interface TypeLiteralNode<M extends ReadOnly> extends TypeNode<M> {
        members: NodeArray<M, Node<M>>;
    }

    export interface ArrayTypeNode<M extends ReadOnly> extends TypeNode<M> {
        elementType: TypeNode<M>;
    }

    export interface StringLiteralTypeNode<M extends ReadOnly> extends TypeNode<M> {
        text: string;
    }

    export interface Expression<M extends ReadOnly> extends Node<M> {
        contextualType?: Type<M>;  // Used to temporarily assign a contextual type during overload resolution
    }

    export interface UnaryExpression<M extends ReadOnly> extends Expression<M> {
        operator: SyntaxKind;
        operand: Expression<M>;
    }

    export interface BinaryExpression<M extends ReadOnly> extends Expression<M> {
        left: Expression<M>;
        operator: SyntaxKind;
        right: Expression<M>;
    }

    export interface ConditionalExpression<M extends ReadOnly> extends Expression<M> {
        condition: Expression<M>;
        whenTrue: Expression<M>;
        whenFalse: Expression<M>;
    }

    export interface FunctionExpression<M extends ReadOnly> extends Expression<M>, FunctionDeclaration<M> {
        body: Node<M>; // Required, whereas the member inherited from FunctionDeclaration is optional
    }

    // The text property of a LiteralExpression stores the interpreted value of the literal in text form. For a StringLiteral
    // this means quotes have been removed and escapes have been converted to actual characters. For a NumericLiteral, the
    // stored value is the toString() representation of the number. For example 1, 1.00, and 1e0 are all stored as just "1".
    export interface LiteralExpression<M extends ReadOnly> extends Expression<M> {
        text: string;
    }

    export interface ParenExpression<M extends ReadOnly> extends Expression<M> {
        expression: Expression<M>;
    }

    export interface ArrayLiteral<M extends ReadOnly> extends Expression<M> {
        elements: NodeArray<M, Expression<M>>;
    }

    export interface ObjectLiteral<M extends ReadOnly> extends Expression<M> {
        properties: NodeArray<M, Node<M>>;
    }

    export interface PropertyAccess<M extends ReadOnly> extends Expression<M> {
        left: Expression<M>;
        right: Identifier<M>;
    }

    export interface IndexedAccess<M extends ReadOnly> extends Expression<M> {
        object: Expression<M>;
        index: Expression<M>;
    }

    export interface CallExpression<M extends ReadOnly> extends Expression<M> {
        func: Expression<M>;
        typeArguments?: NodeArray<M, TypeNode<M>>;
        arguments: NodeArray<M, Expression<M>>;
    }

    export interface NewExpression<M extends ReadOnly> extends CallExpression<M> { }

    export interface TypeAssertion<M extends ReadOnly> extends Expression<M> {
        type: TypeNode<M>;
        operand: Expression<M>;
    }

    export interface Statement<M extends ReadOnly> extends Node<M> { }

    export interface Block<M extends ReadOnly> extends Statement<M> {
        statements: NodeArray<M, Statement<M>>;
    }

    export interface VariableStatement<M extends ReadOnly> extends Statement<M> {
        declarations: NodeArray<M, VariableDeclaration<M>>;
    }

    export interface ExpressionStatement<M extends ReadOnly> extends Statement<M> {
        expression: Expression<M>;
    }

    export interface IfStatement<M extends ReadOnly> extends Statement<M> {
        expression: Expression<M>;
        thenStatement: Statement<M>;
        elseStatement?: Statement<M>;
    }

    export interface IterationStatement<M extends ReadOnly> extends Statement<M> {
        statement: Statement<M>;
    }

    export interface DoStatement<M extends ReadOnly> extends IterationStatement<M> {
        expression: Expression<M>;
    }

    export interface WhileStatement<M extends ReadOnly> extends IterationStatement<M> {
        expression: Expression<M>;
    }

    export interface ForStatement<M extends ReadOnly> extends IterationStatement<M> {
        declarations?: NodeArray<M, VariableDeclaration<M>>;
        initializer?: Expression<M>;
        condition?: Expression<M>;
        iterator?: Expression<M>;
    }

    export interface ForInStatement<M extends ReadOnly> extends IterationStatement<M> {
        declaration?: VariableDeclaration<M>;
        variable?: Expression<M>;
        expression: Expression<M>;
    }

    export interface BreakOrContinueStatement<M extends ReadOnly> extends Statement<M> {
        label?: Identifier<M>;
    }

    export interface ReturnStatement<M extends ReadOnly> extends Statement<M> {
        expression?: Expression<M>;
    }

    export interface WithStatement<M extends ReadOnly> extends Statement<M> {
        expression: Expression<M>;
        statement: Statement<M>;
    }

    export interface SwitchStatement<M extends ReadOnly> extends Statement<M> {
        expression: Expression<M>;
        clauses: NodeArray<M, CaseOrDefaultClause<M>>;
    }

    export interface CaseOrDefaultClause<M extends ReadOnly> extends Node<M> {
        expression?: Expression<M>;
        statements: NodeArray<M, Statement<M>>;
    }

    export interface LabelledStatement<M extends ReadOnly> extends Statement<M> {
        label: Identifier<M>;
        statement: Statement<M>;
    }

    export interface ThrowStatement<M extends ReadOnly> extends Statement<M> {
        expression: Expression<M>;
    }

    export interface TryStatement<M extends ReadOnly> extends Statement<M> {
        tryBlock: Block<M>;
        catchBlock?: CatchBlock<M>;
        finallyBlock?: Block<M>;
    }

    export interface CatchBlock<M extends ReadOnly> extends Block<M> {
        variable: Identifier<M>;
    }

    export interface ClassDeclaration<M extends ReadOnly> extends Declaration<M> {
        typeParameters?: NodeArray<M, TypeParameterDeclaration<M>>;
        baseType?: TypeReferenceNode<M>;
        implementedTypes?: NodeArray<M, TypeReferenceNode<M>>;
        members: NodeArray<M, Node<M>>;
    }

    export interface InterfaceDeclaration<M extends ReadOnly> extends Declaration<M> {
        typeParameters?: NodeArray<M, TypeParameterDeclaration<M>>;
        baseTypes?: NodeArray<M, TypeReferenceNode<M>>;
        members: NodeArray<M, Node<M>>;
    }

    export interface EnumMember<M extends ReadOnly> extends Declaration<M> {
        initializer?: Expression<M>;
    }

    export interface EnumDeclaration<M extends ReadOnly> extends Declaration<M> {
        members: NodeArray<M, EnumMember<M>>;
    }

    export interface ModuleDeclaration<M extends ReadOnly> extends Declaration<M> {
        body: Node<M>;  // Block or ModuleDeclaration
    }

    export interface ImportDeclaration<M extends ReadOnly> extends Declaration<M> {
        entityName?: EntityName<M>;
        externalModuleName?: LiteralExpression<M>;
    }

    export interface ExportAssignment<M extends ReadOnly> extends Statement<M> {
        exportName: Identifier<M>;
    }

    export interface FileReference<M extends ReadOnly> extends TextRange<M> {
        filename: string;
    }

    export interface Comment<M extends ReadOnly> extends TextRange<M> {
        hasTrailingNewLine?: boolean;
    }

    export interface SourceFile<M extends ReadOnly> extends Block<M> {
        filename: string;
        text: string;
        getLineAndCharacterFromPosition(position: number): { line: number; character: number };
        getPositionFromLineAndCharacter(line: number, character: number): number;
        amdDependencies: string[];
        referencedFiles: Array<M, FileReference<M>>;
        syntacticErrors: Array<M, Diagnostic<M>>;
        semanticErrors: Array<M, Diagnostic<M>>;
        hasNoDefaultLib: boolean;
        externalModuleIndicator: Node<M>; // The first node that causes this file to be an external module
        nodeCount: number;
        identifierCount: number;
        symbolCount: number;
        isOpen: boolean;
        version: string;
        languageVersion: ScriptTarget;
        identifiers: Map<M, string>;
    }

    export interface Program<M extends ReadOnly> {
        getSourceFile(filename: string): SourceFile<M>;
        getSourceFiles(): Array<M, SourceFile<M>>;
        getCompilerOptions(): CompilerOptions<M>;
        getCompilerHost(): CompilerHost<M>;
        getDiagnostics(sourceFile?: SourceFile<M>): Array<M, Diagnostic<M>>;
        getGlobalDiagnostics(): Array<M, Diagnostic<M>>;
        getTypeChecker(fullTypeCheckMode: boolean): TypeChecker<M>;
        getCommonSourceDirectory(): string;
    }

    export interface SourceMapSpan<M extends ReadOnly> {
        /** Line number in the js file*/
        emittedLine: number;
        /** Column number in the js file */
        emittedColumn: number;
        /** Line number in the ts file */
        sourceLine: number;
        /** Column number in the ts file */
        sourceColumn: number;
        /** Optional name (index into names array) associated with this span */
        nameIndex?: number;
        /** ts file (index into sources array) associated with this span*/
        sourceIndex: number;
    }

    export interface SourceMapData<M extends ReadOnly> {
        /** Where the sourcemap file is written */
        sourceMapFilePath: string;
        /** source map url written in the js file */
        jsSourceMappingURL: string;
        /** Source map's file field - js file name*/
        sourceMapFile: string;
        /** Source map's sourceRoot field - location where the sources will be present if not "" */
        sourceMapSourceRoot: string;
        /** Source map's sources field - list of sources that can be indexed in this source map*/
        sourceMapSources: string[];
        /** input source file (which one can use on program to get the file)
            this is one to one mapping with the sourceMapSources list*/
        inputSourceFileNames: string[];
        /** Source map's names field - list of names that can be indexed in this source map*/
        sourceMapNames?: string[];
        /** Source map's mapping field - encoded source map spans*/
        sourceMapMappings: string;
        /** Raw source map spans that were encoded into the sourceMapMappings*/
        sourceMapDecodedMappings: Array<M, SourceMapSpan<M>>;
    }

    export interface EmitResult<M extends ReadOnly> {
        errors: Array<M, Diagnostic<M>>;
        sourceMaps: Array<M, SourceMapData<M>>;  // Array of sourceMapData if compiler emitted sourcemaps
    }

    export interface TypeChecker<M extends ReadOnly> {


// TODO: Gradually add these
//         getProgram(): Program;
//         getDiagnostics(sourceFile?: SourceFile): Diagnostic[];
//         getGlobalDiagnostics(): Diagnostic[];
//         getNodeCount(): number;
//         getIdentifierCount(): number;
//         getSymbolCount(): number;
//         getTypeCount(): number;
//         checkProgram(): void;
//         emitFiles(): EmitResult;
//         getParentOfSymbol(symbol: Symbol): Symbol;
//         getTypeOfSymbol(symbol: Symbol): Type;
//         getPropertiesOfType(type: Type): Symbol[];
//         getPropertyOfType(type: Type, propetyName: string): Symbol;
//         getSignaturesOfType(type: Type, kind: SignatureKind): Signature[];
//         getIndexTypeOfType(type: Type, kind: IndexKind): Type;
//         getReturnTypeOfSignature(signature: Signature): Type;
//         getSymbolsInScope(location: Node, meaning: SymbolFlags): Symbol[];
//         getSymbolInfo(node: Node): Symbol;
//         getTypeOfNode(node: Node): Type;
//         getApparentType(type: Type): ApparentType;
//         typeToString(type: Type, enclosingDeclaration?: Node, flags?: TypeFormatFlags): string;
//         symbolToString(symbol: Symbol, enclosingDeclaration?: Node, meaning?: SymbolFlags): string;
//         getAugmentedPropertiesOfApparentType(type: Type): Symbol[];
//         getRootSymbol(symbol: Symbol): Symbol;
//         getContextualType(node: Node): Type;
    }

    export interface TextWriter<M extends ReadOnly> {
        write(s: string): void;
        writeSymbol(symbol: Symbol<M>, enclosingDeclaration?: Node<M>, meaning?: SymbolFlags): void;
        writeLine(): void;
        increaseIndent(): void;
        decreaseIndent(): void;
        getText(): string;
    }

    export enum TypeFormatFlags {
        None                    = 0x00000000,
        WriteArrayAsGenericType = 0x00000001,  // Write Array<T> instead T[]
        UseTypeOfFunction       = 0x00000002,  // Write typeof instead of function type literal
        NoTruncation            = 0x00000004,  // Don't truncate typeToString result
    }

    export enum SymbolAccessibility {
        Accessible,
        NotAccessible,
        CannotBeNamed
    }

    export interface SymbolAccessiblityResult<M extends ReadOnly> {
        accessibility: SymbolAccessibility;
        errorSymbolName?: string // Optional symbol name that results in error
        errorModuleName?: string // If the symbol is not visible from module, module's name
        aliasesToMakeVisible?: Array<M, ImportDeclaration<M>>; // aliases that need to have this symbol visible
    }

    export interface EmitResolver<M extends ReadOnly> {
        getProgram(): Program<M>;
        getLocalNameOfContainer(container: Declaration<M>): string;
        getExpressionNamePrefix(node: Identifier<M>): string;
        getPropertyAccessSubstitution(node: PropertyAccess<M>): string;
        getExportAssignmentName(node: SourceFile<M>): string;
        isReferencedImportDeclaration(node: ImportDeclaration<M>): boolean;
        isTopLevelValueImportedViaEntityName(node: ImportDeclaration<M>): boolean;
        getNodeCheckFlags(node: Node<M>): NodeCheckFlags;
        getEnumMemberValue(node: EnumMember<M>): number;
        shouldEmitDeclarations(): boolean;
        isDeclarationVisible(node: Declaration<M>): boolean;
        isImplementationOfOverload(node: FunctionDeclaration<M>): boolean;
        writeTypeAtLocation(location: Node<M>, enclosingDeclaration: Node<M>, flags: TypeFormatFlags, writer: TextWriter<M>): void;
        writeReturnTypeOfSignatureDeclaration(signatureDeclaration: SignatureDeclaration<M>, enclosingDeclaration: Node<M>, flags: TypeFormatFlags, writer: TextWriter<M>): void;
        writeSymbol(symbol: Symbol<M>, enclosingDeclaration: Node<M>, meaning: SymbolFlags, writer: TextWriter<M>): void;
        isSymbolAccessible(symbol: Symbol<M>, enclosingDeclaration: Node<M>, meaning: SymbolFlags): SymbolAccessiblityResult<M>;
        isImportDeclarationEntityNameReferenceDeclarationVisibile(entityName: EntityName<M>): SymbolAccessiblityResult<M>;
    }

    export enum SymbolFlags {
        Variable           = 0x00000001,  // Variable or parameter
        Property           = 0x00000002,  // Property or enum member
        EnumMember         = 0x00000004,  // Enum member
        Function           = 0x00000008,  // Function
        Class              = 0x00000010,  // Class
        Interface          = 0x00000020,  // Interface
        Enum               = 0x00000040,  // Enum
        ValueModule        = 0x00000080,  // Instantiated module
        NamespaceModule    = 0x00000100,  // Uninstantiated module
        TypeLiteral        = 0x00000200,  // Type Literal
        ObjectLiteral      = 0x00000400,  // Object Literal
        Method             = 0x00000800,  // Method
        Constructor        = 0x00001000,  // Constructor
        GetAccessor        = 0x00002000,  // Get accessor
        SetAccessor        = 0x00004000,  // Set accessor
        CallSignature      = 0x00008000,  // Call signature
        ConstructSignature = 0x00010000,  // Construct signature
        IndexSignature     = 0x00020000,  // Index signature
        TypeParameter      = 0x00040000,  // Type parameter

        // Export markers (see comment in declareModuleMember in binder)
        ExportValue        = 0x00080000,  // Exported value marker
        ExportType         = 0x00100000,  // Exported type marker
        ExportNamespace    = 0x00200000,  // Exported namespace marker

        Import             = 0x00400000,  // Import
        Instantiated       = 0x00800000,  // Instantiated symbol
        Merged             = 0x01000000,  // Merged symbol (created during program binding)
        Transient          = 0x02000000,  // Transient symbol (created during type check)
        Prototype          = 0x04000000,  // Symbol for the prototype property (without source code representation)

// TODO
//         Value     = Variable | Property | EnumMember | Function | Class | Enum | ValueModule | Method | GetAccessor | SetAccessor,
//         Type      = Class | Interface | Enum | TypeLiteral | ObjectLiteral | TypeParameter,
//         Namespace = ValueModule | NamespaceModule,
//         Module    = ValueModule | NamespaceModule,
//         Accessor  = GetAccessor | SetAccessor,
//         Signature = CallSignature | ConstructSignature | IndexSignature,
//
//         ParameterExcludes       = Value,
//         VariableExcludes        = Value & ~Variable,
//         PropertyExcludes        = Value,
//         EnumMemberExcludes      = Value,
//         FunctionExcludes        = Value & ~(Function | ValueModule),
//         ClassExcludes           = (Value | Type) & ~ValueModule,
//         InterfaceExcludes       = Type & ~Interface,
//         EnumExcludes            = (Value | Type) & ~(Enum | ValueModule),
//         ValueModuleExcludes     = Value & ~(Function | Class | Enum | ValueModule),
//         NamespaceModuleExcludes = 0,
//         MethodExcludes          = Value & ~Method,
//         GetAccessorExcludes     = Value & ~SetAccessor,
//         SetAccessorExcludes     = Value & ~GetAccessor,
//         TypeParameterExcludes   = Type & ~TypeParameter,
//
//         // Imports collide with all other imports with the same name.
//         ImportExcludes          = Import,
//
//         ModuleMember = Variable | Function | Class | Interface | Enum | Module | Import,
//
//         ExportHasLocal = Function | Class | Enum | ValueModule,
//
//         HasLocals  = Function | Module | Method | Constructor | Accessor | Signature,
//         HasExports = Class | Enum | Module,
//         HasMembers = Class | Interface | TypeLiteral | ObjectLiteral,
//
//         IsContainer = HasLocals | HasExports | HasMembers,
//         PropertyOrAccessor      = Property | Accessor,
//         Export                  = ExportNamespace | ExportType | ExportValue,
    }

    export interface Symbol<M extends ReadOnly> {

        /*@ (Immutable) flags: { v: bitvector32 | mask_symbolflags_transient v <=>  extends_interface this "ts.TransientSymbol" } */
        flags: SymbolFlags;            // Symbol flags

        name: string;                  // Name of symbol

        /*@ (Mutable) id: number */
        id?: number;                   // Unique id (used to look up SymbolLinks)

        /*@ (Mutable) mergeId: number */
        mergeId?: number;              // Merge id (used to look up merged symbol)

        /*@ declarations : IArray<IDeclaration> */
        declarations?: Array<M, Declaration<M>>;  // Declarations associated with this symbol

        /*@ (Mutable) parent?: ISymbol */
        parent?: Symbol<M>;               // Parent symbol
        members?: SymbolTable<M>;         // Class, interface or literal instance members
        exports?: SymbolTable<M>;         // Module exports
        exportSymbol?: Symbol<M>;         // Exported symbol associated with this symbol
        valueDeclaration?: Declaration<M> // First value declaration of the symbol
    }

    export interface SymbolLinks<M extends ReadOnly> {
        target?: Symbol<M>;               // Resolved (non-alias) target of an alias
        type?: Type<M>;                   // Type of value symbol
        declaredType?: Type<M>;           // Type of class, interface, enum, or type parameter
        mapper?: TypeMapper<M>;           // Type mapper for instantiation alias
        referenced?: boolean;          // True if alias symbol has been referenced as a value
        exportAssignSymbol?: Symbol<M>;   // Symbol exported from external module
    }

    export interface TransientSymbol<M extends ReadOnly> extends Symbol<M>, SymbolLinks<M> { }

    // export interface SymbolTable {
    export interface SymbolTable<M extends ReadOnly> extends Map<M, Symbol<M>> {

        [index: string]: Symbol<Immutable>;

    }

    export enum NodeCheckFlags {
        TypeChecked    = 0x00000001,  // Node<M> has been type checked
        LexicalThis    = 0x00000002,  // Lexical 'this' reference
        CaptureThis    = 0x00000004,  // Lexical 'this' used in body
        EmitExtends    = 0x00000008,  // Emit __extends
        SuperInstance  = 0x00000010,  // Instance 'super' reference
        SuperStatic    = 0x00000020,  // Static 'super' reference
        ContextChecked = 0x00000040,  // Contextual types have been assigned
    }

    export interface NodeLinks<M extends ReadOnly> {
        resolvedType?: Type<M>;            // Cached type of type node
        resolvedSignature?: Signature<M>;  // Cached signature of signature node or call expression
        resolvedSymbol?: Symbol<M>;        // Cached name resolution result
        flags?: NodeCheckFlags;            // Set of flags specific to Node
        enumMemberValue?: number;       // Constant value of enum member
        /*@ (Mutable) isIllegalTypeReferenceInConstraint?: boolean */
        isIllegalTypeReferenceInConstraint?: boolean; // Is type reference in constraint refers to the type parameter from the same list
        isVisible?: boolean;            // Is this node visible
        localModuleName?: string;       // Local name for module instance
    }

    export enum TypeFlags {
        Any                = 0x00000001,
        String             = 0x00000002,
        Number             = 0x00000004,
        Boolean            = 0x00000008,
        Void               = 0x00000010,
        Undefined          = 0x00000020,
        Null               = 0x00000040,
        Enum               = 0x00000080,  // Enum type
        StringLiteral      = 0x00000100,  // String literal type
        TypeParameter      = 0x00000200,  // Type parameter
        Class              = 0x00000400,  // Class
        Interface          = 0x00000800,  // Interface
        Reference          = 0x00001000,  // Generic type reference
        Anonymous          = 0x00002000,  // Anonymous
        FromSignature      = 0x00004000,  // Created for signature assignment check

        //// TODO
        //Intrinsic = Any | String | Number | Boolean | Void | Undefined | Null,
        //StringLike = String | StringLiteral,
        //NumberLike = Number | Enum,
        //ObjectType = Class | Interface | Reference | Anonymous

        // PV : hardcoding the result here
        ObjectType         = 0x00003C00,
    }

    // Properties common to all types
    export interface Type<M extends ReadOnly> {

        /*@ (Immutable) flags: { v: bitvector32 | type_flags(v,this) } */
        flags: TypeFlags;       // Flags

        id: number;             // Unique ID

        /*@ (Immutable) symbol?: ISymbol */
        symbol?: Symbol<M>;     // Symbol associated with type (if any)
    }

    // Intrinsic types (TypeFlags.Intrinsic)
    export interface IntrinsicType<M extends ReadOnly> extends Type<M> {
        intrinsicName: string;  // Name of intrinsic type
    }

    // String literal types (TypeFlags.StringLiteral)
    export interface StringLiteralType<M extends ReadOnly> extends Type<M> {
        text: string;  // Text of string literal
    }

    // Object types (TypeFlags.ObjectType)
    export interface ObjectType<M extends ReadOnly> extends Type<M> { }

    export interface ApparentType<M extends ReadOnly> extends Type<M> {
        // This property is not used. It is just to make the type system think ApparentType
        // is a strict subtype of Type.
        _apparentTypeBrand: any;
    }

    // Class and interface types (TypeFlags.Class and TypeFlags.Interface)
    export interface InterfaceType<M extends ReadOnly> extends ObjectType<M> {
        typeParameters             : Array<M, TypeParameter<M>>; // Type parameters (undefined if non-generic)
        baseTypes                  : Array<M, ObjectType<M>>;    // Base types
        declaredProperties         : Array<M, Symbol<M>>;        // Declared members
        declaredCallSignatures     : Array<M, Signature<M>>;     // Declared call signatures
        declaredConstructSignatures: Array<M, Signature<M>>;     // Declared construct signatures
        declaredStringIndexType    : Type<M>;                    // Declared string index type
        declaredNumberIndexType    : Type<M>;                    // Declared numeric index type
    }

    // Type references (TypeFlags.Reference)
    export interface TypeReference<M extends ReadOnly> extends ObjectType<M> {
        target: GenericType<Immutable>;                         // Type reference target
        /*@ (Immutable) typeArguments: IArray<IType> */
        typeArguments: IArray<IType>;                           // Type reference type arguments
    }

    // Generic class and interface types
    export interface GenericType<M extends ReadOnly> extends InterfaceType<M>, TypeReference<M> {

        // TODO : make the Map<...> work as well

        /*@ (Immutable) instantiations: (Mutable) { [x:string]: TypeReference<Immutable> } */
        instantiations: Map<M, TypeReference<M>>;           // Generic instantiation cache

        openReferenceTargets: Array<M, GenericType<M>>;     // Open type reference targets
        openReferenceChecks: Map<M, boolean>;               // Open type reference check cache
    }

    // Resolved object type
    export interface ResolvedObjectType<M extends ReadOnly> extends ObjectType<M> {
        members: SymbolTable<Immutable>;                    // Properties by name
        properties: IArray<ISymbol>;                        // Properties
        callSignatures: IArray<ISignature>;                 // Call signatures of type
        constructSignatures: IArray<ISignature>;            // Construct signatures of type
        stringIndexType: Type<M>;                           // String index type
        numberIndexType: Type<M>;                           // Numeric index type
    }

    // Type parameters (TypeFlags.TypeParameter)
    export interface TypeParameter<M extends ReadOnly> extends Type<M> {
        constraint: Type<M>;                                // Constraint
        target?: TypeParameter<M>;                          // Instantiation target
        mapper?: TypeMapper<M>;                             // Instantiation mapper
    }

    export enum SignatureKind {
        Call,
        Construct,
    }

    export interface Signature<M extends ReadOnly> {
        declaration: SignatureDeclaration<M>;       // Originating declaration
        typeParameters: Array<M, TypeParameter<M>>; // Type parameters (undefined if non-generic)
        parameters: Array<M, Symbol<M>>;            // Parameters
        resolvedReturnType: Type<M>;                // Resolved return type
        minArgumentCount: number;                   // Number of non-optional parameters
        hasRestParameter: boolean;                  // True if last parameter is rest parameter
        hasStringLiterals: boolean;                 // True if instantiated
        target?: Signature<M>;                      // Instantiation target
        mapper?: TypeMapper<M>;                     // Instantiation mapper
        erasedSignatureCache?: Signature<M>;        // Erased version of signature (deferred)
        isolatedSignatureType?: ObjectType<M>;      // A manufactured type that just contains the signature for purposes of signature comparison
    }

    export enum IndexKind {
        String,
        Number,
    }

    export interface TypeMapper<M extends ReadOnly> {
        <N extends ReadOnly>(t: Type<N>): Type<N>;
    }

    export interface InferenceContext<M extends ReadOnly> {
        typeParameters: Array<M, TypeParameter<M>>;
        inferences: Array<M, Array<M, Type<M>>>;
        inferredTypes: Array<M, Type<M>>;
    }

    export interface DiagnosticMessage<M extends ReadOnly> {
        key: string;
        category: DiagnosticCategory;
        code: number;
    }

    // A linked list of formatted diagnostic messages to be used as part of a multiline message.
    // It is built from the bottom up, leaving the head to be the "main" diagnostic.
    // While it seems that DiagnosticMessageChain is structurally similar to DiagnosticMessage,
    // the difference is that messages are all preformatted in DMC.
    export interface DiagnosticMessageChain<M extends ReadOnly> {
        messageText: string;
        category: DiagnosticCategory;
        code: number;
        next?: DiagnosticMessageChain<M>;
    }

    export interface Diagnostic<M extends ReadOnly> {
        file: SourceFile<M>;
        start: number;
        length: number;
        messageText: string;
        category: DiagnosticCategory;
        code: number;
    }

    export enum DiagnosticCategory {
        Warning,
        Error,
        Message,
    }

    export interface CompilerOptions<M extends ReadOnly> {
        charset?: string;
        codepage?: number;
        declaration?: boolean;
        diagnostics?: boolean;
        emitBOM?: boolean;
        help?: boolean;
        locale?: string;
        mapRoot?: string;
        module?: ModuleKind;
        noErrorTruncation?: boolean;
        noImplicitAny?: boolean;
        noLib?: boolean;
        noLibCheck?: boolean;
        noResolve?: boolean;
        out?: string;
        outDir?: string;
        removeComments?: boolean;
        sourceMap?: boolean;
        sourceRoot?: string;
        target?: ScriptTarget;
        version?: boolean;
        watch?: boolean;
        [option: string]: any;
    }

    export enum ModuleKind {
        None,
        CommonJS,
        AMD,
    }

    export enum ScriptTarget {
        ES3,
        ES5,
    }

    export interface ParsedCommandLine<M extends ReadOnly> {
        options: CompilerOptions<M>;
        filenames: string[];
        errors: Array<M, Diagnostic<M>>;
    }

    export interface CommandLineOption<M extends ReadOnly> {
        name: string;
        type: any;                              // "string", "number", "boolean", or an object literal mapping named values to actual values
        shortName?: string;                     // A short pneumonic for convenience - for instance, 'h' can be used in place of 'help'.
        description?: DiagnosticMessage<M>;     // The message describing what the command line switch does
        paramName?: DiagnosticMessage<M>;       // The name to be used for a non-boolean option's parameter.
        error?: DiagnosticMessage<M>;           // The error given when the argument does not fit a customized 'type'.
    }

    export enum CharacterCodes {
        nullCharacter     = 0x00000000, // 0,
        maxAsciiCharacter = 0x0000007F, // 0x7F,

// TODO
//         lineFeed = 0x0A,              // \n
//         carriageReturn = 0x0D,        // \r
//         lineSeparator = 0x2028,
//         paragraphSeparator = 0x2029,
//         nextLine = 0x0085,
//
//         // Unicode 3.0 space characters
//         space = 0x0020,   // " "
//         nonBreakingSpace = 0x00A0,   //
//         enQuad = 0x2000,
//         emQuad = 0x2001,
//         enSpace = 0x2002,
//         emSpace = 0x2003,
//         threePerEmSpace = 0x2004,
//         fourPerEmSpace = 0x2005,
//         sixPerEmSpace = 0x2006,
//         figureSpace = 0x2007,
//         punctuationSpace = 0x2008,
//         thinSpace = 0x2009,
//         hairSpace = 0x200A,
//         zeroWidthSpace = 0x200B,
//         narrowNoBreakSpace = 0x202F,
//         ideographicSpace = 0x3000,
//         mathematicalSpace = 0x205F,
//         ogham = 0x1680,
//
//         _ = 0x5F,
//         $ = 0x24,
//
//         _0 = 0x30,
//         _1 = 0x31,
//         _2 = 0x32,
//         _3 = 0x33,
//         _4 = 0x34,
//         _5 = 0x35,
//         _6 = 0x36,
//         _7 = 0x37,
//         _8 = 0x38,
//         _9 = 0x39,
//
//         a = 0x61,
//         b = 0x62,
//         c = 0x63,
//         d = 0x64,
//         e = 0x65,
//         f = 0x66,
//         g = 0x67,
//         h = 0x68,
//         i = 0x69,
//         j = 0x6A,
//         k = 0x6B,
//         l = 0x6C,
//         m = 0x6D,
//         n = 0x6E,
//         o = 0x6F,
//         p = 0x70,
//         q = 0x71,
//         r = 0x72,
//         s = 0x73,
//         t = 0x74,
//         u = 0x75,
//         v = 0x76,
//         w = 0x77,
//         x = 0x78,
//         y = 0x79,
//         z = 0x7A,
//
//         A = 0x41,
//         B = 0x42,
//         C = 0x43,
//         D = 0x44,
//         E = 0x45,
//         F = 0x46,
//         G = 0x47,
//         H = 0x48,
//         I = 0x49,
//         J = 0x4A,
//         K = 0x4B,
//         L = 0x4C,
//         M = 0x4D,
//         N = 0x4E,
//         O = 0x4F,
//         P = 0x50,
//         Q = 0x51,
//         R = 0x52,
//         S = 0x53,
//         T = 0x54,
//         U = 0x55,
//         V = 0x56,
//         W = 0x57,
//         X = 0x58,
//         Y = 0x59,
//         Z = 0x5a,
//
//         ampersand = 0x26,             // &
//         asterisk = 0x2A,              // *
//         at = 0x40,                    // @
//         backslash = 0x5C,             // \
//         bar = 0x7C,                   // |
//         caret = 0x5E,                 // ^
//         closeBrace = 0x7D,            // }
//         closeBracket = 0x5D,          // ]
//         closeParen = 0x29,            // )
//         colon = 0x3A,                 // :
//         comma = 0x2C,                 // ,
//         dot = 0x2E,                   // .
//         doubleQuote = 0x22,           // "
//         equals = 0x3D,                // =
//         exclamation = 0x21,           // !
//         greaterThan = 0x3E,           // >
//         lessThan = 0x3C,              // <
//         minus = 0x2D,                 // -
//         openBrace = 0x7B,             // {
//         openBracket = 0x5B,           // [
//         openParen = 0x28,             // (
//         percent = 0x25,               // %
//         plus = 0x2B,                  // +
//         question = 0x3F,              // ?
//         semicolon = 0x3B,             // ;
//         singleQuote = 0x27,           // '
//         slash = 0x2F,                 // /
//         tilde = 0x7E,                 // ~
//
//         backspace = 0x08,             // \b
//         formFeed = 0x0C,              // \f
//         byteOrderMark = 0xFEFF,
//         tab = 0x09,                   // \t
//         verticalTab = 0x0B,           // \v
    }

    export interface CancellationToken<M extends ReadOnly> {
        isCancellationRequested(): boolean;
    }

    export interface CompilerHost<M extends ReadOnly> {
        getSourceFile(filename: string, languageVersion: ScriptTarget, onError?: (message: string) => void): SourceFile<M>;
        getDefaultLibFilename(): string;
        getCancellationToken? (): CancellationToken<M>;
        writeFile(filename: string, data: string, writeByteOrderMark: boolean, onError?: (message: string) => void): void;
        getCurrentDirectory(): string;
        getCanonicalFileName(fileName: string): string;
        useCaseSensitiveFileNames(): boolean;
        getNewLine(): string;
    }

}