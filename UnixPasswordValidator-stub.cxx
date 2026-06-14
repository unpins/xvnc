/* unpins: PAM/system-password authentication stubbed out.
 *
 * UnixPasswordValidator normally authenticates a username/password against the
 * system via PAM (pam_start/pam_authenticate). That is meaningless in a single
 * self-contained static binary — there is no /etc/pam.d and no loadable PAM
 * modules — and libpam itself can't link statically (it's a .so + dlopen design).
 * So we keep the class API (so SSecurityPlain / SSecurityRSAAES still link) but
 * drop the PAM dependency and make validation always fail. The real auth in this
 * build is VncAuth (-PasswordFile) and X509/TLS, which don't touch PAM.
 */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <string>

#include <core/Configuration.h>
#include <core/LogWriter.h>

#include <rfb/UnixPasswordValidator.h>

using namespace rfb;

static core::LogWriter vlog("UnixPasswordValidator");

/* Kept for CLI/config compatibility (-PAMService / -pam_service); no-op here. */
static core::StringParameter pamService
  ("PAMService", "Service name for PAM password validation "
   "(unsupported in this build)", "vnc");
core::AliasParameter pam_service("pam_service", "Alias for PAMService",
                                 &pamService);

std::string UnixPasswordValidator::displayName;

bool UnixPasswordValidator::validateInternal(SConnection * /*sc*/,
                                             const char * /*username*/,
                                             const char * /*password*/,
                                             std::string & /*msg*/)
{
  vlog.error("System-password (PAM) authentication is not available in this "
             "build; use VncAuth (-PasswordFile) or X509/TLS");
  return false;
}
