
function twice<A>(f:(a:A) => A, x0:A): A {
	var x1 = f(x0);
	x1 = f(x1);
	return x1;
}

/*@ foo :: (x:number) => {v:number | v >= x} */
function foo(x:number){
	var z  :number= 0;
  if (random() > 0) {
    z = 10;
  }
	var r :number= x + z;
  assert(r >= x);
  return r;
}
 
/*@ main :: (x:number) => {v:number |v >= x} */
function main(x:number):number{
  return twice(foo, x);
}
