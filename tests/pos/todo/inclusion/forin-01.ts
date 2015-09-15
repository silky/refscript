// Taken from strobe
/*@ qualif Bot(v:a,s:string): hasProperty(v,s) */
/*@ qualif Bot(v:a,s:string): enumProp(v,s) */

/*@ foo :: (o: { [x:string]: string + number }) => { string | true } */ 
function foo(o) {
  for (var x in o) {
    var r = o[x];
    if (typeof r === "string") {
      return r;
    }
  }
  return "no string found";
};