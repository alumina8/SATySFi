(* -*- coding: utf-8 -*- *)

open MyUtil
open LengthInterface
open HorzBox


type frame_breaking =
  | Beginning
  | Midway

type pb_vert_box =
  | PBVertLine             of length * length * intermediate_horz_box list
  | PBVertFixedBreakable   of length
  | PBVertFixedUnbreakable of length
  | PBVertFrame            of frame_breaking * paddings * decoration * decoration * decoration * decoration * length * pb_vert_box list
  | PBClearPage

type pb_accumulator = {
  breakable      : bool;
  badness        : pure_badness;
  solid_body     : evaled_vert_box Alist.t;
  solid_footnote : evaled_vert_box Alist.t;
  discardable    : evaled_vert_box Alist.t;
  total_height   : length;
}

type pb_answer = {
  body         : evaled_vert_box list;
  footnote     : evaled_vert_box Alist.t;
  rest         : (pb_vert_box list) option;
  last_height  : length;
  last_badness : pure_badness;
}


let chop_single_page (pbinfo : page_break_info) (area_height : length) (pbvblst : pb_vert_box list) : evaled_vert_box list * evaled_vert_box list * (pb_vert_box list) option =

  let calculate_badness_of_page_break hgttotal =
    let hgtdiff = area_height -% hgttotal in
      if hgtdiff <% Length.zero then 10000 else
        int_of_float (hgtdiff /% (Length.of_pdf_point 0.1))
  in

  let omit_clear_page_element pbvblst =
    match pbvblst with
    | PBClearPage :: pbvbtail -> pbvbtail
    | _                       -> pbvblst
  in

  let rec aux (prev : pb_accumulator) (pbvblst : pb_vert_box list) : pb_answer =
    let bprev = prev.breakable in
    let vpbprev = prev.badness in
    let evvbacc = prev.solid_body in
    let footnote = prev.solid_footnote in
    let evvbaccdiscardable = prev.discardable in
    let hgttotal = prev.total_height in
    match pbvblst with
    | PBVertLine(hgt, dpt, imhblst) :: pbvbtail ->
        let hgtline = hgt +% (Length.negate dpt) in
        let (evhblst, imvblstlstfootnote) = PageInfo.embed_page_info pbinfo imhblst in
        let (evvblstfootnote, _) = PageInfo.embed_page_info_vert pbinfo (List.concat imvblstlstfootnote) in
          (* -- ignores footnote designation in footnote -- *)
        let hgtnewfootnote = get_height_of_evaled_vert_box_list evvblstfootnote in
        let hgttotalnew = hgttotal +% hgtline +% hgtnewfootnote in
        let vpb = calculate_badness_of_page_break hgttotalnew in
          if bprev && (vpb >= vpbprev) && (hgttotal <% hgttotalnew) then
          (* --
             if getting worse, outputs the accumulated non-discardable lines 'evvbacc' as a page.
             note that the line checked last will be left in the processing list.
             -- *)
            {
              body = Alist.to_list evvbacc;
              footnote = footnote;
              rest = Some(pbvblst);
              last_height = hgttotalnew;
              last_badness = vpb;
            }
          else
            let evvbaccnew = Alist.extend (Alist.cat evvbacc evvbaccdiscardable) (EvVertLine(hgt, dpt, evhblst)) in
            aux {
              breakable = true;
              badness = vpb;
              solid_body = evvbaccnew;
              solid_footnote = Alist.append footnote evvblstfootnote;
              discardable = Alist.empty;
              total_height = hgttotalnew;
            } pbvbtail

    | PBVertFixedBreakable(vskip) :: pbvbtail ->
        let hgttotalnew = hgttotal +% vskip in
        let vpb = calculate_badness_of_page_break hgttotalnew in
          if (vpb >= vpbprev) && (hgttotal <% hgttotalnew) then
            {
              body = Alist.to_list evvbacc;
              footnote = footnote;
              rest = Some(omit_clear_page_element pbvbtail);
              last_height = hgttotalnew;
              last_badness = vpb;
            }
          else
            let evvbaccdiscardablenew = Alist.extend evvbaccdiscardable (EvVertFixedEmpty(vskip)) in
            aux {
              breakable = true;
              badness = vpb;
              solid_body = evvbacc;
              solid_footnote = footnote;
              discardable = evvbaccdiscardablenew;
              total_height = hgttotalnew;
            } pbvbtail

    | PBVertFixedUnbreakable(vskip) :: pbvbtail ->
        let hgttotalnew = hgttotal +% vskip in
        let evvbaccnew = Alist.extend (Alist.cat evvbacc evvbaccdiscardable) (EvVertFixedEmpty(vskip)) in
        aux {
          breakable = false;
          badness = vpbprev;  (* doubtful *)
          solid_body = evvbaccnew;
          solid_footnote = footnote;
          discardable = Alist.empty;
          total_height = hgttotalnew;
        } pbvbtail

    | PBClearPage :: pbvbtail ->
        {
          body = Alist.to_list evvbacc;
          footnote = footnote;
          rest = Some(pbvbtail);
          last_height = hgttotal;
          last_badness = 0;
        }

    | PBVertFrame(midway, pads, decoS, decoH, decoM, decoT, wid, pbvblstsub) :: pbvbtail ->
        let hgttotalbefore = hgttotal +% pads.paddingT in
        let ans =
          aux {
            breakable = false;
            badness = vpbprev;
            solid_body = Alist.empty;
            solid_footnote = footnote;
            discardable = Alist.empty;
            total_height = hgttotalbefore;
          } pbvblstsub
            (* -- propagates total height and footnotes, but does NOT propagate body -- *)
        in
        let hgttotalafter = ans.last_height +% pads.paddingB in
        begin
          match ans.rest with
          | None ->
              let evvbaccnew =
                let (decosub, pads) =
(*
                  match midway with
                  | Midway    -> (decoT, { pads with paddingT = Length.zero; })
                  | Beginning -> (decoS, pads)
*)
                  match midway with
                  | Midway    -> (decoT, pads)
                  | Beginning -> (decoS, pads)
                in
                  Alist.extend (Alist.cat evvbacc evvbaccdiscardable)
                    (EvVertFrame(pads, pbinfo, decosub, wid, ans.body))
              in
              aux {
                breakable = true;
                badness = ans.last_badness;
                solid_body = evvbaccnew;
                solid_footnote = ans.footnote;
                discardable = Alist.empty;
                total_height = hgttotalafter;
              } pbvbtail

          | Some(pbvbrestsub) ->
              let evvbaccret =
                let (decosub, pads) =
(*
                  match midway with
                  | Midway    -> (decoM, { pads with paddingT = Length.zero; paddingB = Length.zero; })
                  | Beginning -> (decoH, { pads with paddingB = Length.zero; })
*)
                  match midway with
                  | Midway    -> (decoM, pads)
                  | Beginning -> (decoH, pads)
                in
                  Alist.extend (Alist.cat evvbacc evvbaccdiscardable)
                    (EvVertFrame(pads, pbinfo, decosub, wid, ans.body))
              in
              let pbvbrest = Some(PBVertFrame(Midway, pads, decoS, decoH, decoM, decoT, wid, pbvbrestsub) :: pbvbtail) in
              {
                body = Alist.to_list evvbaccret;
                footnote = footnote;
                rest = pbvbrest;
                last_height = hgttotalafter;
                last_badness = ans.last_badness;
              }
        end

    | [] ->
        {
          body = Alist.to_list evvbacc;
          footnote = footnote;
          rest = None;
          last_height = hgttotal;
          last_badness = vpbprev;
        }
  in
  let vpbinit = 100000 in
  let ans =
    aux {
      breakable = false;
      badness = vpbinit;
      solid_body = Alist.empty;
      solid_footnote = Alist.empty;
      discardable = Alist.empty;
      total_height = Length.zero;
    } pbvblst
  in
    (ans.body, Alist.to_list ans.footnote, ans.rest)


(* --
   normalize:
     squashes bottom/top margins into spaces.
   -- *)
let normalize (vblst : vert_box list) : pb_vert_box list =

  let rec aux pbvbacc vblst =
    match vblst with
    | []
    | VertTopMargin(_, _) :: []
    | VertBottomMargin(_, _) :: []
        -> Alist.to_list pbvbacc

    | VertLine(hgt, dpt, imhblst) :: vbtail ->
        aux (Alist.extend pbvbacc (PBVertLine(hgt, dpt, imhblst))) vbtail

    | VertFixedBreakable(vskip) :: vbtail ->
        aux (Alist.extend pbvbacc (PBVertFixedBreakable(vskip))) vbtail

    | VertBottomMargin(breakable1, mgn1) :: VertTopMargin(breakable2, mgn2) :: vbtail ->
        if breakable1 && breakable2 then
          aux (Alist.extend pbvbacc (PBVertFixedBreakable(Length.max mgn1 mgn2))) vbtail
        else
          aux (Alist.extend pbvbacc (PBVertFixedUnbreakable(Length.max mgn1 mgn2))) vbtail


    | VertBottomMargin(breakable1, mgn1) :: vbtail ->
        let pbvb = if breakable1 then PBVertFixedBreakable(mgn1) else PBVertFixedUnbreakable(mgn1) in
          aux (Alist.extend pbvbacc pbvb) vbtail

    | VertTopMargin(breakable2, mgn2) :: vbtail ->
        begin
          match Alist.to_list_rev pbvbacc with
          | [] ->
            (* -- ignores the first top margin -- *)
              aux Alist.empty vbtail

          | _ :: _ ->
              let pbvb =
                if breakable2 then
                  PBVertFixedBreakable(mgn2)
                else
                  PBVertFixedUnbreakable(mgn2)
              in
                aux (Alist.extend pbvbacc pbvb) vbtail
        end

    | VertFrame(pads, decoS, decoH, decoM, decoT, wid, vblstsub) :: vbtail ->
        let pbvblstsub = aux Alist.empty vblstsub in
        let pbvb = PBVertFrame(Beginning, pads, decoS, decoH, decoM, decoT, wid, pbvblstsub) in
          aux (Alist.extend pbvbacc pbvb) vbtail

    | VertClearPage :: vbtail ->
        aux (Alist.extend pbvbacc PBClearPage) vbtail

  in
    aux Alist.empty vblst


let solidify (vblst : vert_box list) : intermediate_vert_box list =
  let rec aux pbvblst =
    pbvblst |> List.map (fun pbvb ->
      match pbvb with
      | PBVertLine(hgt, dpt, imhblst) -> ImVertLine(hgt, dpt, imhblst)
      | PBVertFixedBreakable(vskip)   -> ImVertFixedEmpty(vskip)
      | PBVertFixedUnbreakable(vskip) -> ImVertFixedEmpty(vskip)

      | PBVertFrame(_, pads, decoS, decoH, decoM, decoT, wid, pbvblstsub) ->
          let imvblstsub = aux pbvblstsub in
            ImVertFrame(pads, decoS, wid, imvblstsub)

      | PBClearPage -> ImVertFixedEmpty(Length.zero)
    )
  in
  let pbvblst = normalize vblst in
    aux pbvblst


let main (absname_out : abs_path) (pagesize : page_size) (pagecontf : page_content_scheme_func) (pagepartsf : page_parts_scheme_func) (vblst : vert_box list) : HandlePdf.t =

  let pdfinit = HandlePdf.create_empty_pdf absname_out in

  let rec aux pageno (pdfacc : HandlePdf.t) pbvblst =
    let pbinfo = { current_page_number = pageno; } in
    let pagecontsch = pagecontf pbinfo in  (* -- invokes the page scheme function -- *)
    let (evvblstpage, footnote, restopt) = chop_single_page pbinfo pagecontsch.page_content_height pbvblst in

    let page = HandlePdf.make_page pagesize pbinfo pagecontsch evvblstpage footnote in
    let pdfaccnew = pdfacc |> HandlePdf.write_page page pagepartsf in
      match restopt with
      | None              -> pdfaccnew
      | Some(imvblstrest) -> aux (pageno + 1) pdfaccnew imvblstrest
  in
  let pbvblst = normalize vblst in
    aux 1 pdfinit pbvblst


let adjust_to_first_line (imvblst : intermediate_vert_box list) =
  let rec aux optinit totalhgtinit imvblst =
    imvblst |> List.fold_left (fun (opt, totalhgt) imvb ->
      match (imvb, opt) with
      | (ImVertLine(hgt, dpt, _), None)  -> (Some(totalhgt +% hgt), totalhgt +% hgt +% (Length.negate dpt))
      | (ImVertLine(hgt, dpt, _), _)     -> (opt, totalhgt +% hgt +% (Length.negate dpt))
      | (ImVertFixedEmpty(vskip), _)     -> (opt, totalhgt +% vskip)

      | (ImVertFrame(pads, _, _, imvblstsub), _) ->
          let totalhgtbefore = totalhgt +% pads.paddingT in
          let (optsub, totalhgtsub) = aux opt totalhgtbefore imvblstsub in
          let totalhgtafter = totalhgtsub +% pads.paddingB in
            (optsub, totalhgtafter)

    ) (optinit, totalhgtinit)
  in
    match aux None Length.zero imvblst with
    | (Some(hgt), totalhgt) -> (hgt, Length.negate (totalhgt -% hgt))
    | (None, totalhgt)      -> (Length.zero, Length.negate totalhgt)


let adjust_to_last_line (imvblst : intermediate_vert_box list) =
  let rec aux optinit totalhgtinit evvblst =
    let evvblstrev = List.rev evvblst in
      evvblstrev |> List.fold_left (fun (opt, totalhgt) imvblast ->
        match (imvblast, opt) with
        | (ImVertLine(hgt, dpt, _), None)  -> (Some((Length.negate totalhgt) +% dpt), totalhgt +% (Length.negate dpt) +% hgt)
        | (ImVertLine(hgt, dpt, _), _)     -> (opt, totalhgt +% (Length.negate dpt) +% hgt)
        | (ImVertFixedEmpty(vskip), _)     -> (opt, totalhgt +% vskip)

        | (ImVertFrame(pads, _, _, evvblstsub), _) ->
            let totalhgtbefore = totalhgt +% pads.paddingB in
            let (optsub, totalhgtsub) = aux opt totalhgtbefore evvblstsub in
            let totalhgtafter = totalhgtsub +% pads.paddingT in
              (optsub, totalhgtafter)

      ) (optinit, totalhgtinit)
  in
    match aux None Length.zero imvblst with
    | (Some(dpt), totalhgt) -> (totalhgt +% dpt, dpt)
    | (None, totalhgt)      -> (totalhgt, Length.zero)


(*
let penalty_break_space = 100
let penalty_soft_hyphen = 1000

let () =
  let ( ~% ) = Length.of_pdf_point in
  begin
    FontInfo.initialize () ;
    let font0 = ("Arno", ~% 16.) in
    let font1 = (* ("Hlv", ~% 16.) *) font0 in
    let fontL = (* ("Hlv", ~% 32.) *) ("Arno", ~% 32.) in

    let fontK = (* ("KozMin", ~% 12.) *) ("Osaka", ~% 12.) in

    let word s = HorzPure(PHFixedString(font0, InternalText.of_utf_8 s)) in
    let word1 s = HorzPure(PHFixedString(font1, InternalText.of_utf_8 s)) in
    let wordL s = HorzPure(PHFixedString(fontL, InternalText.of_utf_8 s)) in

    let wordK s = HorzPure(PHFixedString(fontK, InternalText.of_utf_8 s)) in

    let margin = ~% 2. in
    let pads = {
      paddingL = ~% 2. +% margin;
      paddingR = ~% 2. +% margin;
      paddingT = ~% 2. +% margin;
      paddingB = ~% 2. +% margin;
    } in
    let decostd =
      (fun (xpos, ypos) wid hgt dpt ->
        let xposb = xpos +% margin in
        let hgtb = hgt -% margin in
        let dptb = dpt +% margin in
        let widb = wid -% margin *% 2. in
        [
          Rectangle((xposb, ypos +% dptb), (widb, hgtb -% dptb));
        ]
      )
    in
    let decoH =
      (fun (xpos, ypos) wid hgt dpt ->
        let xposb = xpos +% margin in
        let hgtb = hgt -% margin in
        let dptb = dpt +% margin in
        let widb = wid -% margin in
        [
          GeneralPath((xposb +% widb, ypos +% hgtb), [
            LineTo(xposb, ypos +% hgtb);
            LineTo(xposb, ypos +% dptb);
            LineTo(xposb +% widb, ypos +% dptb);
          ]);
        ]
      )
    in
    let decoM =
      (fun (xpos, ypos) wid hgt dpt ->
        let xposb = xpos in
        let hgtb = hgt -% margin in
        let dptb = dpt +% margin in
        let widb = wid in
        [
          GeneralPath((xposb, ypos +% hgtb), [LineTo(xposb +% widb, ypos +% hgtb)]);
          GeneralPath((xposb, ypos +% dptb), [LineTo(xposb +% widb, ypos +% dptb)]);
        ]
      )
    in
    let decoT =
      (fun (xpos, ypos) wid hgt dpt ->
        let xposb = xpos in
        let hgtb = hgt -% margin in
        let dptb = dpt +% margin in
        let widb = wid -% margin in
        [
          GeneralPath((xposb, ypos +% hgtb), [
            LineTo(xposb +% widb, ypos +% hgtb);
            LineTo(xposb +% widb, ypos +% dptb);
            LineTo(xposb, ypos +% dptb);
          ]);
        ]
      )
    in
    let framed hblst = HorzPure(PHOuterFrame(pads, decostd, hblst)) in
    let iframed hblst = HorzPure(PHInnerFrame(pads, decostd, hblst)) in
    let fframed wid hblst = HorzPure(PHFixedFrame(pads, wid, decostd, hblst)) in
    let bframed hblst = HorzFrameBreakable(pads, ~% 5., ~% 5., decostd, decoH, decoM, decoT, hblst) in
    let space = HorzDiscretionary(penalty_break_space, Some(PHOuterEmpty(~% 6., ~% 2., ~% 3.)), None, None) in
    let space1 = HorzDiscretionary(penalty_break_space, Some(PHOuterEmpty(~% 7.5, ~% 3., ~% 3.)), None, None) in
    let spaceL = HorzDiscretionary(penalty_break_space, Some(PHOuterEmpty(~% 16., ~% 2., ~% 6.)), None, None) in
    let indentation = HorzPure(PHFixedEmpty(~% 64.)) in
    let fill = HorzPure(PHOuterFil) in
    let leading = ~% 24. in
    let paragraph_skip = ~% 16. in
    let soft_hyphen = HorzDiscretionary(penalty_soft_hyphen, None, Some(PHFixedString(font0, InternalText.of_utf_8 "-")), None) in
    let soft_hyphen1 = HorzDiscretionary(penalty_soft_hyphen, None, Some(PHFixedString(font1, InternalText.of_utf_8 "-")), None) in
    let rec repeat n lst = if n <= 0 then [] else lst @ (repeat (n - 1) lst) in
    let vblst =
      [
        VertParagraph(~% 24., [
          fill; wordL "Sample"; spaceL; wordL "Text"; fill;
        ]);
        VertFixedBreakable(paragraph_skip);
        VertParagraph(~% 24., [
          framed [fill; wordL "Sample"; spaceL; wordL "Text"; fill;];
        ]);
        VertFixedBreakable(paragraph_skip);
        VertParagraph(leading, [
          word "discre"; soft_hyphen; word "tionary"; space; word "hyphen"; space;
          word "discre"; soft_hyphen; word "tionary"; space; word "hyphen"; space;
          word "discre"; soft_hyphen; word "tionary"; space; word "hyphen"; space;
          word "The"; space; word "quick"; space; word "brown"; space; word "fox"; space;
          word "jumps"; space; word "over"; space; word "the"; space; word "lazy"; space; word "dog.";
          space;
          word "My"; space; word "quiz"; space; word "above"; space; word "the"; space; word "kiwi"; space; word "juice"; space;
          word "needs"; space; word "price"; soft_hyphen ; word "less"; space; word "fixing."; space;
          word "fluffy"; space; word "soufflés"; space; word "office"; space; word "Té"; fill;
        ]);

        VertFixedBreakable(paragraph_skip);
        VertParagraph(leading, [
          word "Now"; space; word "we"; space; word "deal"; space; word "with"; space;
          framed [word1 "kerning"; space; word1 "pair";]; space; word "information!"; fill;
        ]);

        VertFixedBreakable(paragraph_skip);
        VertParagraph(leading, [
(*
          wordK "スペーシングの上"; space; wordK "行分割"; space; wordK "されてるけど，"; space;
          wordK "これでも"; space; wordK "和文フォントが"; space; wordK "埋め込まれた"; space;
          wordK "立派な"; space; wordK "PDF"; space; wordK "です。"; space;
          wordK "←"; space; wordK "しかし"; space; wordK "見ての通り"; space;
          wordK "メトリック情報の"; space; wordK "埋め込みに"; space; wordK "関しては"; space; wordK "不完全。";
          space;
          word1 "A"; space1;
*)
          framed [
            word1 "My"; space1; word1 "quiz"; space1; word1 "above"; space1; word1 "the"; space1; framed [word1 "kiwi"; space1; word1 "juice";];]; space1;
            word1 "needs"; space1; word1 "price"; soft_hyphen1 ; word1 "less"; space1; word1 "fixing.";
          fill;
        ]);

        VertFixedBreakable(paragraph_skip);
        VertParagraph(leading, [
(*
          wordK "スペーシングの上"; space; wordK "行分割"; space; wordK "されてるけど，"; space;
          wordK "これでも"; space; wordK "和文フォントが"; space; wordK "埋め込まれた"; space;
          wordK "立派な"; space; wordK "PDF"; space; wordK "です。"; space;
          wordK "←"; space; wordK "しかし"; space; wordK "見ての通り"; space;
          wordK "メトリック情報の"; space; wordK "埋め込みに"; space; wordK "関しては"; space; wordK "不完全。";
*)
          word1 "A"; space1;
          iframed [
            word1 "My"; space1; word1 "quiz"; space1; word1 "above"; space1; word1 "the"; space1; iframed [word1 "kiwi"; space1; word1 "juice";];]; space1;
            word1 "needs"; space1; word1 "price"; soft_hyphen1 ; word1 "less"; space1; word1 "fixing.";
          fill;
        ]);
(*
        VertFixedBreakable(paragraph_skip);
        VertParagraph(~% 20., [
          wordK "スペーシングの上"; space; wordK "行分割"; space; wordK "されてるけど，"; space;
          wordK "これでも"; space; wordK "和文フォントが"; space; wordK "埋め込まれた"; space;
          wordK "立派な"; space; wordK "PDF"; space; wordK "です。"; space;
          wordK "←"; space; wordK "しかし"; space; wordK "見ての通り"; space;
          wordK "メトリック情報の"; space; wordK "埋め込みに"; space; wordK "関しては"; space; wordK "不完全。";
          fframed (~% 300.) [
            word1 "My"; space1; word1 "quiz"; space1; word1 "above"; space1; word1 "the"; space1; fframed (~% 120.) [word1 "kiwi"; space1; word1 "juice";];]; space1;
            word1 "needs"; space1; word1 "price"; soft_hyphen1 ; word1 "less"; space1; word1 "fixing.";
          fill;
        ]);
*)
        VertFixedBreakable(paragraph_skip);
        VertParagraph(leading, [
          indentation;
          bframed [
            word1 "Lorem"; space1; word1 "ipsum"; space1; word1 "dolor"; space1; word1 "sit"; space1; word1 "amet,"; space1;
            word1 "consectetur"; space1; word1 "adipiscing"; space1; word1 "elit,"; space1;
            word1 "sed"; space1; word1 "do"; space1; word1 "eiusmod"; space1; word1 "tempor"; space1; word1 "incididunt"; space1;
            word1 "ut"; space1; word1 "labore"; space1; word1 "et"; space1; word1 "dolore"; space1; word1 "magna"; space1; word1 "aliqua."; space1;
            bframed [
              word1 "Ut"; space1; word1 "enim"; space1; word1 "ad"; space1; word1 "minim"; space1; word1 "veniam,";
            ]; space1;
            word1 "quis"; space1; word1 "nostrud"; space1; word1 "exercitation"; space1; word1 "ullamco"; space1;
            word1 "laboris"; space1; word1 "nisi"; space1; word1 "ut"; space1; word1 "aliquip"; space1;
            word1 "ex"; space1; word1 "ea"; space1; word1 "commodo"; space1; word1 "consequat.";

          ]; fill;
        ]);

      ] @ repeat 2 [
        VertFixedBreakable(paragraph_skip);
        VertParagraph(leading, [
          indentation;
          word1 "Lorem"; space; word1 "ipsum"; space; word "dolor"; space; word "sit"; space; word "amet,"; space;
          word "consectetur"; space; word "adipiscing"; space; word "elit,"; space;
          word "sed"; space; word "do"; space; word "eiusmod"; space; word "tempor"; space; word "incididunt"; space;
          word "ut"; space; word "labore"; space; word "et"; space; word "dolore"; space; word "magna"; space; word "aliqua."; space;
          word "Ut"; space; word "enim"; space; word "ad"; space; word "minim"; space; word "veniam,"; space;
          word " quis"; space; word "nostrud"; space; word "exercitation"; space; word "ullamco"; space;
          word "laboris"; space; word "nisi"; space; word "ut"; space; word "aliquip"; space;
          word "ex"; space; word "ea"; space; word "commodo"; space; word "consequat."; space;
          word "Duis"; space; word "aute"; space; word "irure"; space; word "dolor"; space;
          word "in"; space; word "reprehenderit"; space; word "in"; space; word "voluptate"; space;
          word "velit"; space; word "esse"; space; word "cillum"; space; word "dolore"; space;
          word "eu"; space; word "fugiat"; space; word "nulla"; space; word "pariatur."; space;
          word "Excepteur"; space; word "sint"; space; word "occaecat"; space; word "cupidatat"; space;
          word "non"; space; word "proident,"; space; word "sunt"; space; word "in"; space; word "culpa"; space;
          word "qui"; space; word "officia"; space; word "deserunt"; space; word "mollit"; space; word "anim"; space;
          word "id"; space; word "est"; space; word "laborum."; fill;
        ]);
      ]
    in
    let pdfscheme = HandlePdf.create_empty_pdf "hello5.pdf" in
    try
      begin
        main_for_unit_test pdfscheme vblst ;
      end
    with
    | FontFormat.FontFormatBroken(e) -> Otfm.pp_error Format.std_formatter e
  end
*)
