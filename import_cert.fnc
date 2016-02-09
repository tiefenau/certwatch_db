/* certwatch_db - Database schema
 * Written by Rob Stradling
 * Copyright (C) 2015-2016 COMODO CA Limited
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

CREATE OR REPLACE FUNCTION import_cert(
	cert_data				bytea
) RETURNS certificate.ID%TYPE
AS $$
DECLARE
	t_certificateID		certificate.ID%TYPE;
	t_verified			boolean		:= FALSE;
	t_canIssueCerts		boolean;
	t_issuerCAID		certificate.ISSUER_CA_ID%TYPE;
	t_name				ca.NAME%TYPE;
	t_brand				ca.BRAND%TYPE;
	t_publicKey			ca.PUBLIC_KEY%TYPE;
	t_caID				ca.ID%TYPE;
	l_ca				RECORD;
BEGIN
	IF cert_data IS NULL THEN
		RETURN NULL;
	END IF;

	SELECT c.ID
		INTO t_certificateID
		FROM certificate c
		WHERE digest(c.CERTIFICATE, 'sha256')
					= digest(cert_data, 'sha256');
	IF t_certificateID IS NOT NULL THEN
		RETURN t_certificateID;
	END IF;

	t_canIssueCerts := x509_canIssueCerts(cert_data);
	IF t_canIssueCerts THEN
		t_name := x509_subjectName(cert_data);
		t_publicKey := x509_publicKey(cert_data);
		IF t_publicKey IS NULL THEN
			t_brand := 'Bad Public Key';
			t_publicKey := E'\\x00';
		END IF;

		SELECT ca.ID
			INTO t_caID
			FROM ca
			WHERE ca.NAME = t_name
				AND ca.PUBLIC_KEY IN (t_publicKey, E'\\x00');
		IF t_caID IS NULL THEN
			INSERT INTO ca (
					NAME, PUBLIC_KEY, BRAND
				)
				VALUES (
					t_name, t_publicKey, t_brand
				)
				RETURNING ca.ID
					INTO t_caID;
		END IF;
		t_issuerCAID := t_caID;
	END IF;

	FOR l_ca IN (
				SELECT *
					FROM ca
					WHERE ca.NAME = x509_issuerName(cert_data)
						AND ca.PUBLIC_KEY != E'\\x00'
					ORDER BY octet_length(PUBLIC_KEY) DESC
			) LOOP
		t_issuerCAID := l_ca.ID;
		IF x509_verify(cert_data, l_ca.PUBLIC_KEY) THEN
			t_verified := TRUE;
			EXIT;
		END IF;
	END LOOP;

	INSERT INTO certificate (
			CERTIFICATE, ISSUER_CA_ID
		)
		VALUES (
			cert_data, t_issuerCAID
		)
		RETURNING ID
			INTO t_certificateID;

	PERFORM extract_cert_names(t_certificateID, t_issuerCAID);

	IF t_canIssueCerts THEN
		INSERT INTO ca_certificate (
				CERTIFICATE_ID, CA_ID
			)
			VALUES (
				t_certificateID, t_caID
			);
	END IF;

	IF NOT t_verified THEN
		INSERT INTO invalid_certificate (
				CERTIFICATE_ID
			)
			VALUES (
				t_certificateID
			);
	END IF;

	RETURN t_certificateID;

EXCEPTION
	WHEN others THEN
		RETURN NULL;
END;
$$ LANGUAGE plpgsql;
