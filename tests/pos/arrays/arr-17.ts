
// XXX: TODO : get the comments from object literal types

/*@ where :: ( ) => { IArray<number> | (len v) = 5 } */
function where( ) {
	let result = new Array<number>(5);
	return result;
}