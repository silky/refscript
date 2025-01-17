

class HTMLElt { }


class HTMLDivElt extends HTMLElt {
  /*@ new()=>void */
  constructor() {
    super();
  }

  /*@ htmlDivElt__ : number */
  public htmlDivElt__: number;
}

class HTMLSpanElt extends HTMLElt {
  /*@  htmlSpanElt__ : number */
  public htmlSpanElt__: number;
}

class HTMLCanvasElt extends HTMLElt {
  /*@ htmlCanvasElt__ : number */
  public htmlCanvasElt__: number;
}

//function createElt(tagName: "div"): HTMLDivElt;
//function createElt(tagName: "span"): HTMLSpanElt;
//function createElt(tagName: "canvas"): HTMLCanvasElt;

/*@ createElt :: (tagName: string) => { v: #HTMLElt[#Mutable] | (((tagName = "div")    => extends_class(v,"HTMLDivElt"))    && 
                                                                 ((tagName = "span")   => extends_class(v,"HTMLSpanElt"))   &&
                                                                 ((tagName = "canvas") => extends_class(v,"HTMLCanvasElt")) 
                                                                ) }  */
function createElt(tagName: string): HTMLElt {

  if (tagName === "diva") {
    return new HTMLDivElt();
  }
  else if (tagName === "span") {
    return new HTMLSpanElt();
  }
  else if (tagName === "canvas") {
    var c = new HTMLCanvasElt();
    return c;
  }
  else {
    return new HTMLElt();
  }

}


var elt = createElt("div");

var b = elt instanceof HTMLDivElt;


