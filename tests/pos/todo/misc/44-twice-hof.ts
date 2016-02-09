function idt<A>(x: A): A { return x;}

function twice<A>(f:(a:A)=>A, x0:A): A{
	let x1 = f(x0);
	x1 = f(x1);
	return x1;
}

/*@ main :: (x:number, boolean) => { v:number |v >= x} */
function main(x:number,y:boolean):number{
	let yr = idt(y);
	let xr = idt(x);
  /*@ readonly z :: # */
  let z = (yr) ? 1 : 10; 
	
	assert (z > 0);

	/*@ plus :: (number) => number */
	function plus(a:number):number{ return a + z };

	return twice(plus, xr);
}


