/*@ foo :: () => { number | true } */
function foo() {
  var i: any = 0; 
  while (i < 5) {
    i = "dog"; // whoops, should be same as outside.
  }
  return i;
}

