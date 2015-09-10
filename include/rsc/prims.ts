
 /*  builtin_BIBracketRef :: <M,A>(x: Array<M,A>, n: number + undefined) => A + undefined */
 /*  builtin_BIBracketRef :: <M,A>(x: Array<M,A>, n: undefined) => undefined */
 /*  builtin_BIBracketRef :: <A>  (o: [Immutable] {[y: string]: A }, x: string) => { A | has Property(x,o) } + { undefined | not (hasProperty(x,o)) } */

/*@ builtin_BIBracketRef :: <A>(x: IArray<A> , n: idx<x>)  => A */
/*@ builtin_BIBracketRef :: <A>(x: MArray<A> , n: number)  => A + undefined */
/*@ builtin_BIBracketRef :: <A>({[y: string]: A }, string) => A + undefined */
declare function builtin_BIBracketRef<A>(a: A[], n: number): A;

// TODO : add case for A<AssignsFields> or A<Unique>

/*@ builtin_BIBracketAssign :: <A>(x: IArray<A> , n: idx<x>, v: A) => void */
/*@ builtin_BIBracketAssign :: <M extends ReadOnly,A>(x: Array<M,A>, n: number, v: A) => void */
/*@ builtin_BIBracketAssign :: <A>(a: {[y: string]: A}, s: string, v: A) => void */
declare function builtin_BIBracketAssign<A>(a: any, s: any, v: A): void;

/*@ builtin_BISetProp :: <A,M>({ f?: [M] A }      , A) => { A | true } */    // XXX: UniqueMutable ??
/*@ builtin_BISetProp :: <A>  ({ f?: [Mutable] A }, A) => { A | true } */
declare function builtin_BISetProp<A>(o: { f: A }, v: A): A;

/*@ builtin_BIArrayLit :: <M,A>(A) => {v: Array<M,A> | (len v) = builtin_BINumArgs } */
declare function builtin_BIArrayLit<A>(a: A): A[];

/*@ builtin_BICondExpr :: <C,T>(c: C, t: T, x: T, y: T) => { v: T | (if (Prop(c)) then (v ~~ x) else (v ~~ y)) } */
declare function builtin_BICondExpr<C, T>(c: C, t: T, x: T, y: T): T;

type CAST_T = any

/*  builtin_BICastExpr :: <V extends CAST_T>(x: V) => { v: V | v = x } */
/*@ builtin_BICastExpr :: <V extends CAST_T>(x: V) => V */
declare function builtin_BICastExpr<V extends CAST_T>(x: V): V;

// /*@ builtin_OpLT ::
//     /\ (x:number, y:number) => {v:boolean | ((Prop v) <=> (x <  y)) }
//     /\ forall T. (x:T, y:T) => {boolean | true}
//  */
// declare function builtin_OpLT(a: any, b: any): boolean;
//
// /*@ builtin_OpLEq ::
//     /\ (x:number, y:number) => {v:boolean | ((Prop v) <=> (x <= y)) }
//     /\ forall T. (x:T, y:T) => {boolean | true}
//  */
// declare function builtin_OpLEq(a: any, b: any): boolean;
//
// /*@ builtin_OpGT ::
//     /\ (x:number, y:number) => {v:boolean | ((Prop v) <=> (x >  y)) }
//     /\ forall T. (x:T, y:T) => {boolean | true}
//  */
// declare function builtin_OpGT(a: any, b: any): boolean;
//
// /*@ builtin_OpGEq ::
//     /\ (x:number, y:number) => {v:boolean | ((Prop v) <=> (x >= y)) }
//     /\ forall T. (x:T, y:T) => {boolean | true}
//  */
// declare function builtin_OpGEq(a: any, b: any): boolean;
//
// /*@ builtin_OpAdd ::
//     /\ (x:number, y:number) => {number | v = x + y}
//     /\ (x:bitvector32, y:bitvector32) => { bitvector32 | true }
//     /\ (x:number, y:string) => {string | true}
//     /\ (x:string, y:number) => {string | true}
//     /\ (x:string, y:string) => {string | true}
//     /\ (x:string, y:boolean) => {string | true}
//     /\ (x:boolean, y:string) => {string | true}
//  */
// declare function builtin_OpAdd(a: any, b: any): any;
//
// /*@ builtin_OpSub ::
//     (x:number, y:number)  => {v:number | v ~~ x - y}
// */
// declare function builtin_OpSub(a: number, b: number): number;
//
// /*@ builtin_OpMul ::
//     (x: number, y: number) => { v:number | [ v = x * y ;
//                                              (x > 0 && y > 0) => v > 0 ;
//                                              (x < 0 && y < 0) => v > 0 ;
//                                              (x = 0 || y = 0) => v = 0 ] }
//  */
// declare function builtin_OpMul(a: number, b: number): number;
//
// /*@ builtin_OpDiv ::
//     (x: number, {y: number | y != 0}) => {v:number | (x > 0 && y > 1) => (0 <= v && v < x)}
//  */
// declare function builtin_OpDiv(a: number, b: number): number;
//
// declare function builtin_OpMod(a: number, b: number): number;
//
// /*@ builtin_PrefixPlus ::
//     (x:number) => {v:number  | v ~~ x}
//  */
// declare function builtin_PrefixPlus(a: number): number;
//
// /*@ builtin_PrefixMinus ::
//     (x:number) => {v:number  | v ~~ (0 - x)}
//  */
// declare function builtin_PrefixMinus(a: number): number;
//
// /*@ builtin_OpSEq ::
//     /\ forall A   . (x:A, y:A) => {v:boolean | ((Prop v) <=> (x ~~ y)) }
//     /\ forall A B . (x:A, y:B) => {v:boolean | (not (Prop v)) }
//  */
// declare function builtin_OpSEq<A,B>(x: A, y: B): boolean;
//
// /*@ builtin_OpSNEq ::
//     /\ forall A   . (x:A, y:A) => {v:boolean | ((Prop v) <=> (not (x ~~ y))) }
//     /\ forall A B . (x:A, y:B) => {v:boolean | (Prop v) }
//  */
// declare function builtin_OpSNEq<A,B>(x: A, y: B): boolean;
//
// /*@ builtin_OpLAnd ::
//     /\ forall B. (x: undefined, y:B) => {undefined | true}
//     /\ forall B. (x: null     , y:B) => {null | true}
//     /\ forall A. (x:A, y:A) => { v:A | (if (Prop(x)) then (v = y) else (v = x)) }
//     /\ forall A B. (x:A, y:B) => { v:top | (Prop(v) <=> (Prop(x) && Prop(y))) }
//  */
// declare function builtin_OpLAnd(x: any, y: any): any;
//
// /*@ builtin_OpLOr ::
//     /\ forall A. (x: undefined, y:A) => { v:A | v ~~ y }
//     /\ forall A. (x: null, y:A) => { v:A | v ~~ y }
//     /\ forall A. (x:A, y:A) => { v:A | if (not (Prop x)) then (v = y) else (v = x) }
//     /\ forall A B. (x:A, y:B)  => { v:top | (Prop(v) <=> (Prop(x) || Prop(y))) }
//  */
// declare function builtin_OpLOr(x: any, y: any): any;
//
// /*@ builtin_PrefixLNot ::
//     forall A. (x: A) => {v:boolean | (Prop v) <=> (not (Prop x))}
//  */
// declare function builtin_PrefixLNot<A>(x: A): boolean;
//
// /*@ builtin_PrefixBNot ::
//     (x: number) => {v:number | v = 0 - (x + 1) }
//  */
// declare function builtin_PrefixBNot(n: number): number;
//
// /*@ builtin_OpBOr ::
//     (a: bitvector32, b: bitvector32) => { v: bitvector32 | v = bvor(a,b) }
//  */
// declare function builtin_OpBOr(a: number, b: number): number;
// declare function builtin_OpBXor(a: number, b: number): number;
//
// /*@ builtin_OpBAnd ::
//     (a: bitvector32, b: bitvector32) => { v: bitvector32 | v = bvand(a,b) }
//  */
// declare function builtin_OpBAnd(a: number, b: number): number;
// declare function builtin_OpLShift(a: number, b: number): number;
// /*@ builtin_OpSpRShift ::
//     (a: { number | v >= 0 }, b: { number | v >= 0}) => { number | v >= 0 }
//  */
// declare function builtin_OpSpRShift(a: number, b: number): number;
// declare function builtin_OpZfRShift(a: number, b: number): number;
//
// /*   predicate bv_truthy(b) = (b /= (lit "#x00000000" (BitVec (Size32 obj)))) */
//
//
// /**
//  *
//  *    for ... in ...
//  *
//  *    https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Statements/for...in
//  *
//  *    A for...in loop only iterates over enumerable properties. Objects created from
//  *    built–in constructors like Array and Object have inherited non–enumerable
//  *    properties from Object.prototype and String.prototype, such as String's
//  *    indexOf() method or Object's toString() method. The loop will iterate over all
//  *    enumerable properties of the object itself and those the object inherits from
//  *    its constructor's prototype (properties closer to the object in the prototype
//  *    chain override prototypes' properties).
//  *
//  */
//
// /*@ builtin_BIForInKeys ::
//     /\ forall A . (a: IArray<A>)                 => IArray<{ number | (0 <= v && v < (len a)) }>
//     /\            (o: Object<Immutable>)         => IArray<{ string | (hasProperty(v,o) && enumProp(v,o)) }>
//     /\            (o: [Immutable]{ })            => IArray<{ string | (hasProperty(v,o) && enumProp(v,o)) }>
//     /\ forall A . (o: [Immutable]{[s:string]:A}) => IArray<{ string | (hasProperty(v,o) && enumProp(v,o)) }>
//  */
// //TODO: remove the last overload once {[s:string]:A} extends { }
// declare function builtin_BIForInKeys(obj: Object): string[];
//
//
//
// /*************************************************************************
//  *
//  *          RUN-TIME TAGS
//  *
//  ************************************************************************/
//
// /*@ builtin_PrefixTypeof ::
//     forall A. (x:A) => {v:string | (ttag x) = v }
//  */
// declare function builtin_PrefixTypeof<A>(x: A): string;
//
// /*@ builtin_BITruthy ::
//     /\ (b: bitvector32) => { v: boolean | ((Prop v) <=> (b /= (lit "#x00000000" (BitVec (Size32 obj))))) }
//     /\ forall A. (x:A)  => { v: boolean | ((Prop v) <=> Prop(x)) }
// */
// declare function builtin_BITruthy<A>(x: A): boolean;
//
// /*@ builtin_BIFalsy ::
//     forall A. (x:A) => { v:boolean | ((Prop v) <=> (not Prop(x))) }
// */
// declare function builtin_BIFalsy<A>(x: A): boolean;
//
// // HACK
// /*@ invariant {v:undefined | [(ttag(v) = "undefined"); not (Prop(v))]} */
//
// /*@ invariant {v:null | [(ttag(v) = "object"); not (Prop v) ]} */
//
// /*@ invariant {v:boolean | [(ttag(v) = "boolean")]} */
//
// /*@ invariant {v:string | [(ttag(v) = "string"); (Prop(v) <=> v /= "" )]} */
//
// /*@ invariant {v:number | [(ttag(v)  =  "number"); (Prop(v) <=> v /= 0  )]}	*/
//
//
//
// /**
//  *
//  *    ... `instanceof` ...
//  *
//  *    extends_class(x,s): this boolean value is true if value x has been
//  *    constructed by a constructor named with string s. This should NOT be used
//  *    with all nominal types (e.g. interfaces), but just classes (since they are
//  *    the only ones associated with a constructor).
//  *
//  */
//
// /*@ builtin_OpInstanceof ::
//     forall A . (x:A, s: string) => { v: boolean | (Prop(v) <=> extends_class(x,s)) }
// */
// declare function builtin_OpInstanceof<A>(x: A, s: string): boolean;
//
//
// /**
//  *
//  *    ... `in` ...
//  *
//  *   https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/in
//  *
//  *   The in operator returns true for properties in the prototype chain.
//  *
//  */
//
// /*@ builtin_OpIn ::
//     /\ forall A . (i: number, a: IArray<A>) => { v: boolean | ((Prop v) <=> (0 <= i && i < (len a))) }
//     /\            (s: string, o: { }      ) => { v: boolean | ((Prop v) <=> hasProperty(s,o)) }
//  */
// declare function builtin_OpIn(s: string, obj: Object): boolean;
//
//
//
//
// /* ************************************************************************
//  *
//  *        ERROR HANDLING
//  *
//  * ***********************************************************************/
// //
// // // NOTE: types that are defined in lib.d.ts need to be in comment to pass
// // // through the TS compilation phase.
// //
// // interface Error {
// //     name: string;
// //     message: string;
// // }
// //
// // declare var Error: {
// //     new (message?: string): Error;
// //     (message?: string): Error;
// //     prototype: Error;
// // }
//
//
//
// /*************************************************************************
//  *
//  *      MUTABILITY
//  *
//  *      Do not include type parameters here
//  *
//  ************************************************************************/
//
// // /*@ interface ReadOnly */
// // interface ReadOnly { }
// //
// // /*@ interface Immutable extends ReadOnly */
// // interface Immutable extends ReadOnly {
// //     immutable__: void;
// // }
// //
// // /*@ interface Mutable extends ReadOnly */
// // interface Mutable extends ReadOnly {
// //     mutable__: void;
// // }
// //
// // /*@ interface UniqueMutable extends Mutable */
// // interface UniqueMutable extends Mutable {
// //     unique_mutable__: void;
// // }
// //
// // /*@ interface AnyMutability extends ReadOnly */
// // interface AnyMutability extends ReadOnly {
// //     defaultMut__: void;
// // }
//
//
// /*************************************************************************
//  *
//  *  GENERAL PURPOSE AUXILIARY DEFINITIONS
//  *
//  ************************************************************************/
//
// /*@ crash :: forall A. () => A */
// declare function crash(): any;
//
// /*@ assume :: forall A . (x:A) => {v:void | Prop x} */
// declare function assume<A>(x: A): void;
//
// /*@ assert :: forall A . ({x:A|(Prop x)}) => void */
// declare function assert<A>(x: A): void;
//
// /*@ random :: () => {v:number | true} */
// declare function random(): number;
//
// /*@ pos :: () => {v:number | v > 0} */
// declare function pos(): number;
//
// declare function alert(s: string): void;
//
// /*@ isNaN :: (x:undefined + number) => {v:boolean | Prop v <=> (ttag(v) != "number")} */
// declare function isNaN(x:any) : boolean;
