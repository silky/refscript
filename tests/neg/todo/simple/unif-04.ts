//adapted from transducers

class Foo<T> {
    constructor() { }
}

/*@ reduce ::    (Foo<Immutable, boolean>, string) => { void | 0 < 1 } */
/*@ reduce :: <T>(Foo<Immutable, T>,       number) => { void | 0 < 1 } */
export function reduce(xf, coll) {
    if (typeof coll === "number") {
        /*@ xxf :: Foo<Immutable, boolean> */
        var xxf = xf;
    }
}
