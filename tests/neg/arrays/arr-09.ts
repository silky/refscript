
/*@ qualif Length(v:number): (len v) = 3 */

/*@ a :: IArray<number> */
var a = [1,2,3];

/*@ b :: { IArray<number> | len v = 4 } */
var b = [1,2,3,4];

assert(a.length + b.length === 8);
