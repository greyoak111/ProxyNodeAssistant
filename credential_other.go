//go:build !windows

package main

func credentialWrite(target, userName, secret string) error {
	return errCredentialManagerUnsupported
}

func credentialRead(target string) (string, error) {
	return "", errCredentialManagerUnsupported
}

func credentialDelete(target string) error {
	return errCredentialManagerUnsupported
}
