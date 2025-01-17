
/*@ foo :: () => { v: number | v = 4 } */
function foo ():number {
  var obj = {f1: {f11: 1} };
  
  // OK
  // return obj.f1.f11 + obj.f1.f11 + obj.f1.f11;

  // BAD: 
  return obj["f1"].f11 + obj.f1["f11"] + obj["f1"]["f11"];
}

var objNoAnnot = { f: 1, g: "str" }

