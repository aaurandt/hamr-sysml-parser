::/*#! 2> /dev/null                                 #
@ 2>/dev/null # 2>nul & echo off & goto BOF         #
if [ -z ${SIREUM_HOME} ]; then                      #
  echo "Please set SIREUM_HOME env var"             #
  exit -1                                           #git
fi                                                  #
exec ${SIREUM_HOME}/bin/sireum slang run "$0" "$@"  #
:BOF
setlocal
if not defined SIREUM_HOME (
  echo Please set SIREUM_HOME env var
  exit /B -1
)
%SIREUM_HOME%\bin\sireum.bat slang run "%0" %*
exit /B %errorlevel%
::!#*/
// #Sireum

import org.sireum._
import Util._

val home: Os.Path = Os.slashDir.up.canon
val sireum: Os.Path = Os.path(Os.env("SIREUM_HOME").get) / "bin" / (if (Os.isWin) "sireum.bat" else "sireum")
val versions = home / "versions.properties"

val cleanup: B = T

val keywords: ISZ[String] = ISZ("\"GUMBO\"", "@strictpure", "@pure", "@spec")

val sysmlVersion: String = "2026-04" // https://github.com/Systems-Modeling/SysML-v2-Pilot-Implementation/tags
val gumboVersion: String = "4.20260903.fffceb9" // https://github.com/sireum/aadl-gumbo/tags

val antlr4Version: String =
  if (versions.exists) versions.properties.get("org.antlr%antlr4-runtime%").get
  else Sireum.versions.get("org.antlr:antlr4-runtime:").get

assert(ops.StringOps(proc"$sireum hamr sysml translator --help".runCheck().out).contains(sysmlVersion), s"Translator isn't using version $sysmlVersion")


val sysmlUrl: String = s"https://raw.githubusercontent.com/Systems-Modeling/SysML-v2-Pilot-Implementation/${sysmlVersion}/org.omg.sysml.xtext/src-gen/org/omg/sysml/xtext/parser/antlr/internal/InternalSysML.g"
val sysmlUrlH: String = s"https://raw.githubusercontent.com/Systems-Modeling/SysML-v2-Pilot-Implementation/%version/org.omg.sysml.xtext/src-gen/org/omg/sysml/xtext/parser/antlr/internal/InternalSysML.g"
val gumboUrl: String = s"https://raw.githubusercontent.com/sireum/aadl-gumbo/${gumboVersion}/org.sireum.aadl.gumbo/src-gen/org/sireum/aadl/gumbo/parser/antlr/internal/InternalGumbo.g"
val kermlUrl: String = "https://raw.githubusercontent.com/Systems-Modeling/SysML-v2-Pilot-Implementation/%version/org.omg.kerml.xtext/src-gen/org/omg/kerml/xtext/parser/antlr/internal/InternalKerML.g"
val kermlExpUrl: String = s"https://raw.githubusercontent.com/Systems-Modeling/SysML-v2-Pilot-Implementation/${sysmlVersion}/org.omg.kerml.expressions.xtext/src-gen/org/omg/kerml/expressions/xtext/parser/antlr/internal/InternalKerMLExpressions.g"

def translate(outDir: Os.Path, outFileName: String,
              isUrl: B,
              version: Option[String], uri: String): Os.Path = {
  val fName = outDir / outFileName
  val args = (ISZ[String](sireum.string, "hamr", "sysml", "translator", "--keywords", st"${(keywords, ",")}".render) ++ (if (isUrl) ISZ("--version", version.get, "--url", uri) else ISZ("--grammar", uri))) :+ fName.value
  val results = Sireum.procCheck(Os.proc(args).echo.console, message.Reporter.create)
  if (!results.ok) {
    halt(s"Failed to translate: $uri")
  }
  return fName
}

def regenAntrl(grammarFile: Os.Path, outDir: Os.Path): Unit = {
  val deps = Coursier.fetch(Sireum.scalaVer, ISZ(s"org.antlr:antlr4:$antlr4Version"), Coursier.Proxy.empty)
  val classpath: ISZ[String] = for (dep <- deps) yield dep.path.string
  val java = Os.path(Sireum.javaHomePathString) / "bin" / (if (Os.isWin) "java.exe" else "java")
  Os.proc(ISZ(java.string, "-cp", st"${(classpath, Os.pathSep)}".render, "org.antlr.v4.Tool", "-o",
    outDir.string, "-Xexact-output-dir", "-package", "org.sireum.hamr.sysml.parser", (grammarFile).string)).echo.console.runCheck()
  println(s"Generated lexer/parser for $grammarFile")
}

val parserDir: Os.Path = home / "src" / "org" / "sireum" / "hamr" / "sysml" / "parser"
parserDir.removeAll()

val sysmlOrig = parserDir / "InternalSysML_orig.g"
sysmlOrig.downloadFrom(sysmlUrl)
val gumboOrig = parserDir / "InternalGumbo.g"
gumboOrig.downloadFrom(gumboUrl)

var sysmlMod = replace(sysmlOrig.read, searchTextRep, origTextRep, modTextRep)

val gumbo = ops.StringOps(gumboOrig.read)

val gumboStartPos = gumbo.stringIndexOf("// Rule GumboLibrary")
val gumboEndPos = gumbo.stringIndexOf("// Entry rule entryRuleSlangStmt")
assert (gumboStartPos > 0 && gumboEndPos > 0, s"${gumboStartPos} .. ${gumboEndPos}" )

val gumboMinusSlangExp = gumbo.substring(gumboStartPos, gumboEndPos - 1)

val gumboSub =
  st"""${lastSysmlRule}
      |
      |/***************************************
      | * GUMBO START
      | **************************************/
      |
      |$gumboMinusSlangExp
      |
      |/***************************************
      | * GUMBO END
      | **************************************/""".render

sysmlMod = replace(sysmlMod, searchLastSysmlRule, lastSysmlRule, gumboSub)

val rgc    = "RULE_REGULAR_COMMENT : '/*' ( options {greedy=false;} : . )*'*/';"
val rgcMod = "RULE_REGULAR_COMMENT : '/*' ~('{') ( options {greedy=false;} : . )* '*/';"

sysmlMod = replace(sysmlMod, rgc, rgc, rgcMod)

val sysmlp = parserDir / "InternalSysML_mod.g"
sysmlp.writeOver(sysmlMod)


val sysmlg = translate(parserDir, "SysMLv2.g4", F, None(), sysmlp.value)
addTemporalExpressions(sysmlg)
unreserveGumboKeywords(sysmlg, gumboMinusSlangExp, sysmlOrig.read)
fixSL_Note(sysmlg)
changeComment(sysmlg, sysmlUrl, gumboUrl)
regenAntrl(sysmlg, parserDir)


val kermlg = translate(parserDir, "KerMLv2.g4", T, Some(sysmlVersion), kermlUrl)
fixSL_Note(kermlg)
regenAntrl(kermlg, parserDir)

{ // just sysmlv2 + kerml exp
  val sysmlorigg = translate(parserDir, "SysMLv2_SansGumbo.g4", T, Some(sysmlVersion), sysmlUrlH)
  fixSL_Note(sysmlorigg)
  regenAntrl(sysmlorigg, parserDir)
  if (cleanup) {
    for (f <- Os.Path.walk(parserDir, T, T, p => ops.StringOps(p.name).startsWith("SysMLv2_SansGumbo") && p.name != "SysMLv2_SansGumbo.g4")) {
      f.removeOnExit()
    }
  }
}

{ // just gumbo with the Slang expression lang replaced by KerML's
  val kermlExpOrig = parserDir / "KermlExp_orig.g"
  kermlExpOrig.downloadFrom(kermlExpUrl)
  val opsKermlExpOrig = ops.StringOps(kermlExpOrig.read)
  val kermlExpressionLang = opsKermlExpOrig.substring(opsKermlExpOrig.stringIndexOf("// Entry rule entryRuleOwnedExpressionMember"), opsKermlExpOrig.size)

  val gumboMinusSlang = gumbo.substring(0, gumboEndPos - 1)
  val gumbop = parserDir / "Internal_Gumbo_mod.g"
  val gumboContents =
    st"""$gumboMinusSlang
        |
        | // KerML's expression language
        |
        |$kermlExpressionLang"""
  gumbop.writeOver(gumboContents.render)
  val justGumbo = translate(parserDir, "GUMBO.g4", F, Some(gumboVersion), gumbop.value)
  regenAntrl(justGumbo, parserDir)

  if (cleanup) {
    kermlExpOrig.removeOnExit()
    gumbop.removeOnExit()
    val dels = Os.Path.walk(parserDir, T, T, p => ops.StringOps(p.name).startsWith("GUMBO")  && p.name != "GUMBO.g4" && p.name != "GUMBO.tokens")
    for(d <- dels) {
      d.removeOnExit()
    }
  }
}

if (cleanup) {
  sysmlp.removeOnExit()
  sysmlOrig.removeOnExit()
  gumboOrig.removeOnExit()
}

object Util {
  // KerML has no GUMBO temporal operators, so restore that precedence layer after translation.
  def addTemporalExpressions(path: Os.Path): Unit = {
    val o = "ruleAndExpression: ruleEqualityExpression ( (ruleAndOperator ruleEqualityExpression | ruleConditionalAndOperator ruleEqualityExpressionReference))*;"
    val m =
      st"""ruleAndExpression: ruleBinaryTemporalExpression ( (ruleAndOperator ruleBinaryTemporalExpression | ruleConditionalAndOperator ruleBinaryTemporalExpressionReference))*;
          |
          |ruleBinaryTemporalExpressionReference: ruleBinaryTemporalExpression;
          |
          |ruleBinaryTemporalExpression: ruleUnaryTemporalExpression (ruleTemporalBinaryOperator ruleTemporalInterval ruleUnaryTemporalExpression)*;
          |
          |ruleUnaryTemporalExpression: ruleTemporalUnaryOperator ruleTemporalInterval ruleUnaryTemporalExpression | ruleEqualityExpression;
          |
          |ruleTemporalUnaryOperator: 'Future' | 'Eventually' | 'Globally' | 'Always' | 'Once' | 'Historically';
          |
          |ruleTemporalBinaryOperator: 'Until' | 'Release' | 'Since' | 'Trigger';
          |
          |ruleTemporalInterval: '[' RULE_DECIMAL_VALUE ',' RULE_DECIMAL_VALUE ']';""".render
    path.writeOver(replace(path.read, o, o, m))
  }

  // Splicing GUMBO into SysMLv2 makes every GUMBO parser-rule literal an implicit ANTLR token, so a
  // GUMBO keyword shadows any SysMLv2 identifier spelled the same way. The SysML v2 pilot models use
  // 'on' as a state name and 'monitor' as an action name, and an older release used 'cases'. Widen
  // ruleName so those stay usable as names.
  //
  // The set is computed (GUMBO's spliced keywords minus SysMLv2's own) rather than curated, so a new
  // GUMBO keyword is covered automatically. Subtracting SysMLv2's keywords is the safety property:
  // unreserving one of its own ('state', 'case', 'if', ...) would break SysMLv2 itself.
  //
  // Keywords are added inside the existing #ruleName1 alternative on purpose: SysMLAstBuilder.visitName
  // matches on RuleName1Context and reads getChild(0) as a TerminalNode, so no AST builder change is
  // needed. A new labelled alternative would fall through to its halt.
  def unreserveGumboKeywords(path: Os.Path, gumboPortion: String, sysmlPortion: String): Unit = {
    // added by addTemporalExpressions, so not present in either input
    val temporal: ISZ[String] = ISZ("Future", "Eventually", "Globally", "Always", "Once",
      "Historically", "Until", "Release", "Since", "Trigger")

    val sysmlKws = keywordsOf(sysmlPortion)
    val content = path.read
    var kws = HashSSet.empty[String]
    for (k <- keywordsOf(gumboPortion).elements ++ temporal) {
      if (!sysmlKws.contains(k)) {
        // Guard: only unreserve something that really is a keyword in the generated grammar.
        // Listing a non-keyword would create a new reserved word instead of removing one.
        if (!ops.StringOps(content).contains(st"'$k'".render)) {
          halt(s"unreserveGumboKeywords: '$k' is not a keyword in ${path.name}")
        }
        kws = kws + k
      }
    }

    val alts: ISZ[ST] = for (k <- kws.elements) yield st"| '$k'"
    val o =
      st"""ruleName:
          |  RULE_ID #ruleName1
          |  | RULE_UNRESTRICTED_NAME #ruleName2;""".render
    val m =
      st"""ruleName:
          |  ( RULE_ID
          |  ${(alts, "\n  ")} ) #ruleName1
          |  | RULE_UNRESTRICTED_NAME #ruleName2;""".render
    println(st"Unreserved ${kws.size} GUMBO keywords in ruleName: ${(kws.elements, ", ")}".render)
    path.writeOver(replace(content, o, o, m))
  }

  // Keyword literals appearing in parser rules. Lexer rules are skipped so that character literals
  // such as 'a'..'z' in RULE_ID are not mistaken for keywords.
  @pure def keywordsOf(content: String): HashSSet[String] = {
    var r = HashSSet.empty[String]
    for (line <- ops.StringOps(content).split((c: C) => c == '\n')) {
      if (!isLexerRuleLine(line)) {
        val cis = conversions.String.toCis(line)
        var i = 0
        while (i < cis.size) {
          if (cis(i) == '\'') {
            var j = i + 1
            while (j < cis.size && cis(j) != '\'') {
              j = j + 1
            }
            if (j < cis.size) {
              val lit = ops.StringOps(line).substring(i + 1, j)
              if (isIdentifier(lit)) {
                r = r + lit
              }
              i = j + 1
            } else {
              i = cis.size
            }
          } else {
            i = i + 1
          }
        }
      }
    }
    return r
  }

  @strictpure def isIdStart(c: C): B = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'

  @strictpure def isIdPart(c: C): B = isIdStart(c) || (c >= '0' && c <= '9')

  @pure def isIdentifier(s: String): B = {
    val cis = conversions.String.toCis(s)
    if (cis.size == 0 || !isIdStart(cis(0))) {
      return F
    }
    var i = 1
    while (i < cis.size) {
      if (!isIdPart(cis(i))) {
        return F
      }
      i = i + 1
    }
    return T
  }

  // A lexer rule (or fragment) starts with an upper-case/underscore name followed by ':'.
  @pure def isLexerRuleLine(line: String): B = {
    val cis = conversions.String.toCis(line)
    var i = 0
    while (i < cis.size && (cis(i) == ' ' || cis(i) == '\t')) {
      i = i + 1
    }
    if (i >= cis.size) {
      return F
    }
    val c0 = cis(i)
    if (!((c0 >= 'A' && c0 <= 'Z') || c0 == '_')) {
      return F
    }
    while (i < cis.size) {
      val c = cis(i)
      if (c == ':') {
        return T
      }
      if (!isIdPart(c) && c != ' ' && c != '\t') {
        return F
      }
      i = i + 1
    }
    return F
  }

  def replace(content: String, searchStr: String, from: String, to: String): String = {
    val o = ops.StringOps(content)
    val s = o.stringIndexOf(searchStr)
    assert (s > 0, s"$s : $searchStr")
    return (
    st"""${o.substring(0, s - 1)}
        |$to
        |${o.substring(s + from.size + 1, o.size)}""".render)
  }

  def fixSL_Note(path: Os.Path): Unit = {
    val o = "RULE_SL_NOTE: '//' (~('\\n' | '\\r') ~('\\n' | '\\r')*)? ('\\r'? '\\n')? -> channel(HIDDEN);"
    val m = "RULE_SL_NOTE: '//' ~'*' (~('\\n' | '\\r') ~('\\n' | '\\r')*)? ('\\r'? '\\n')? -> channel(HIDDEN);"
    path.writeOver(replace(path.read, o, o, m))
  }

  def changeComment(p: Os.Path, sysmlUrl: String, gumboUrl: String): Unit = {
    val c = ops.StringOps(p.read)
    val pos = c.stringIndexOf("grammar ")
    p.writeOver(
      st"""// Custom SysMLv2 grammar in which GUMBO (minus its expression language) has been injected and
          |// with modifications made to rules 'ruleTextualRepresentation' and 'RULE_REGULAR_COMMENT'
          |//
          |// Original grammars obtained from:
          |//   $sysmlUrl
          |//   $gumboUrl
          |
          |${c.substring(pos, c.size)}""".render)
  }

  val searchTextRep: String = st"""		(
                                  |			(
                                  |				lv_language_3_0=RULE_STRING_VALUE""".render

  val origTextRep: String = st"""		(
                                |			(
                                |				lv_language_3_0=RULE_STRING_VALUE
                                |				{
                                |					newLeafNode(lv_language_3_0, grammarAccess.getTextualRepresentationAccess().getLanguageSTRING_VALUETerminalRuleCall_2_0());
                                |				}
                                |				{
                                |					if ($$current==null) {
                                |						$$current = createModelElement(grammarAccess.getTextualRepresentationRule());
                                |					}
                                |					setWithLastConsumed(
                                |						$$current,
                                |						"language",
                                |						lv_language_3_0,
                                |						"org.omg.kerml.expressions.xtext.KerMLExpressions.STRING_VALUE");
                                |				}
                                |			)
                                |		)
                                |		(
                                |			(
                                |				lv_body_4_0=RULE_REGULAR_COMMENT
                                |				{
                                |					newLeafNode(lv_body_4_0, grammarAccess.getTextualRepresentationAccess().getBodyREGULAR_COMMENTTerminalRuleCall_3_0());
                                |				}
                                |				{
                                |					if ($$current==null) {
                                |						$$current = createModelElement(grammarAccess.getTextualRepresentationRule());
                                |					}
                                |					setWithLastConsumed(
                                |						$$current,
                                |						"body",
                                |						lv_body_4_0,
                                |						"org.omg.kerml.expressions.xtext.KerMLExpressions.REGULAR_COMMENT");
                                |				}
                                |			)
                                |		)""".render

  val modTextRep: String = st"""		(
                               |			(
                               |				otherlv_3='"GUMBO"'
                               |				{
                               |					newLeafNode(otherlv_3, grammarAccess.getTextualRepresentationAccess().getGUMBOKeyword_2_0_0());
                               |				}
                               |				otherlv_4='/*{'
                               |				{
                               |					newLeafNode(otherlv_4, grammarAccess.getTextualRepresentationAccess().getSolidusAsteriskLeftCurlyBracketKeyword_2_0_1());
                               |				}
                               |				(
                               |					(
                               |						otherlv_5='library'
                               |						{
                               |							newLeafNode(otherlv_5, grammarAccess.getTextualRepresentationAccess().getLibraryKeyword_2_0_2_0_0());
                               |						}
                               |						{
                               |							newCompositeNode(grammarAccess.getTextualRepresentationAccess().getGumboLibraryParserRuleCall_2_0_2_0_1());
                               |						}
                               |						ruleGumboLibrary
                               |						{
                               |							afterParserOrEnumRuleCall();
                               |						}
                               |					)
                               |					    |
                               |					{
                               |						newCompositeNode(grammarAccess.getTextualRepresentationAccess().getGumboSubclauseParserRuleCall_2_0_2_1());
                               |					}
                               |					ruleGumboSubclause
                               |					{
                               |						afterParserOrEnumRuleCall();
                               |					}
                               |				)
                               |				otherlv_8='}*/'
                               |				{
                               |					newLeafNode(otherlv_8, grammarAccess.getTextualRepresentationAccess().getRightCurlyBracketAsteriskSolidusKeyword_2_0_3());
                               |				}
                               |			)
                               |			    |
                               |			(
                               |				(
                               |					(
                               |						lv_language_9_0=RULE_STRING_VALUE
                               |						{
                               |							newLeafNode(lv_language_9_0, grammarAccess.getTextualRepresentationAccess().getLanguageSTRING_VALUETerminalRuleCall_2_1_0_0());
                               |						}
                               |						{
                               |							if ($$current==null) {
                               |								$$current = createModelElement(grammarAccess.getTextualRepresentationRule());
                               |							}
                               |							setWithLastConsumed(
                               |								$$current,
                               |								"language",
                               |								lv_language_9_0,
                               |								"org.omg.kerml.expressions.xtext.KerMLExpressions.STRING_VALUE");
                               |						}
                               |					)
                               |				)
                               |				(
                               |					(
                               |						lv_body_10_0=RULE_REGULAR_COMMENT
                               |						{
                               |							newLeafNode(lv_body_10_0, grammarAccess.getTextualRepresentationAccess().getBodyREGULAR_COMMENTTerminalRuleCall_2_1_1_0());
                               |						}
                               |						{
                               |							if ($$current==null) {
                               |								$$current = createModelElement(grammarAccess.getTextualRepresentationRule());
                               |							}
                               |							setWithLastConsumed(
                               |								$$current,
                               |								"body",
                               |								lv_body_10_0,
                               |								"org.omg.kerml.expressions.xtext.KerMLExpressions.REGULAR_COMMENT");
                               |						}
                               |					)
                               |				)
                               |			)
                               |		)""".render

  val searchLastSysmlRule: String = "// Rule RequirementVerificationKind"

  val lastSysmlRule: String = st"""// Rule RequirementVerificationKind
                                  |ruleRequirementVerificationKind returns [Enumerator current=null]
                                  |@init {
                                  |	enterRule();
                                  |}
                                  |@after {
                                  |	leaveRule();
                                  |}:
                                  |	(
                                  |		enumLiteral_0='verify'
                                  |		{
                                  |			$$current = grammarAccess.getRequirementVerificationKindAccess().getRequirementEnumLiteralDeclaration().getEnumLiteral().getInstance();
                                  |			newLeafNode(enumLiteral_0, grammarAccess.getRequirementVerificationKindAccess().getRequirementEnumLiteralDeclaration());
                                  |		}
                                  |	)
                                  |;""".render
}
