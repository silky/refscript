
//adapted from navier-stokes

// M is the implicit mutability for a class
class Foo {
  /*@ a : [Immutable] number */
  a;

  /*@ new (x: number) => { v: Foo<M> | offset(v,"a") ~~ x } */
  constructor(x) { this.a = x }

  /*@ bar : (x: {number | v = this.a}) : {number | v = 0} */
  bar(x) { 
    return this.a - x;
  }
}

var z = new Foo(5)

z.bar(6);
