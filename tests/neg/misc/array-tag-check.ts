interface Foo<T> {}
/*@ stringReduce :: (xf:Foo<Immutable, string>) => {void | 0 < 1} */
declare function stringReduce(xf);

/*@ reduce :: /\ (xf: Foo<Immutable, number>, coll:Array<Immutable, number>) => {void | 0 < 1}
              /\ (xf: Foo<Immutable, string>, coll:string)                   => {void | 0 < 1} */
function reduce(xf, coll) {
  if(typeof coll === "object") {
    stringReduce(xf);
  }
}
