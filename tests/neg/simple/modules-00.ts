module M {

    /*@ s :: { string | v = "hello" } */
    export var s = "hello";

    /*@ f :: () => { string | v = "aaa" } */
    export function f() {
        return s;
    }
}

M.f();