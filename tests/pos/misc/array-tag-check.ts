interface Foo<T> {}
/*@ stringReduce :: (xf:Foo<Immutable, string>) => {void | true} */
declare function stringReduce(xf);

/*@ reduce :: /\ (xf: Foo<Immutable, number>, coll: IArray<number>) => {void | true}
              /\ (xf: Foo<Immutable, string>, coll:string)          => {void | true} */
function reduce(xf, coll) {
  if(typeof coll === "string") {
    stringReduce(xf);
  }
}
